import SwiftUI

@main
struct CinnySwiftApp: App {
    @State private var store = Store()
    var body: some Scene {
        WindowGroup {
            Group {
                if store.session == nil { LoginView() } else { MainView() }
            }
            .environment(store)
            .alert("Error", isPresented: Binding(get: { store.errorMessage != nil && store.session != nil },
                                                  set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }
    }
}

// MARK: - Login
struct LoginView: View {
    @Environment(Store.self) private var store
    @State private var server = "matrix.org"
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Cinny").font(.largeTitle.bold())
            Text("Yet another Matrix client").foregroundStyle(.secondary)
            TextField("Homeserver", text: $server).textFieldStyle(.roundedBorder)
            TextField("Username", text: $user).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                .onSubmit(go)
            if let e = store.errorMessage { Text(e).foregroundStyle(.red).font(.callout) }
            Button(action: go) { if busy { ProgressView() } else { Text("Log in").frame(maxWidth: .infinity) } }
                .buttonStyle(.borderedProminent).disabled(busy || user.isEmpty || password.isEmpty)
        }
        .padding(28).frame(maxWidth: 380)
        #if os(iOS)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
    }
    func go() { busy = true; Task { await store.login(server: server, user: user, password: password); busy = false } }
}

// MARK: - Avatars
struct AuthImage: View {
    @Environment(Store.self) private var store
    let mxc: String; let size: Int
    @State private var image: Image?
    var body: some View {
        Group { if let image { image.resizable().scaledToFill() } else { Color.gray.opacity(0.2) } }
            .task(id: mxc) {
                guard let api = store.api, let url = api.thumbnailURL(mxc: mxc, size: size * 2) else { return }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(api.token ?? "")", forHTTPHeaderField: "Authorization")
                guard let (data, _) = try? await URLSession.shared.data(for: req) else { return }
                #if os(macOS)
                if let i = NSImage(data: data) { image = Image(nsImage: i) }
                #else
                if let i = UIImage(data: data) { image = Image(uiImage: i) }
                #endif
            }
    }
}

struct Avatar: View {
    let name: String; var mxc: String?; var size: CGFloat = 36
    var body: some View {
        ZStack {
            if let mxc { AuthImage(mxc: mxc, size: Int(size)) }
            else {
                Color(hue: Double(abs(name.hashValue) % 360) / 360, saturation: 0.45, brightness: 0.7)
                Text(String(name.drop(while: { !$0.isLetter && !$0.isNumber }).prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.28))
    }
}

// MARK: - Main (Sidebar + room list + timeline)
struct MainView: View {
    @Environment(Store.self) private var store
    @State private var joinTarget = ""
    @State private var showJoin = false


    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: Binding(get: { store.selectedRoom }, set: { if let id = $0 { store.select(id) } })) {
                if !store.invites.isEmpty {
                    Section("Invites") {
                        ForEach(store.invites) { InviteRow(room: $0) }
                    }
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            spaceButton(nil, "Home")
                            ForEach(store.spaces) { spaceButton($0.id, $0.displayName(me: store.me), $0.avatarMxc) }
                        }
                    }
                }
                Section("Rooms") { ForEach(store.visibleRooms) { RoomRow(room: $0) } }
                if !store.directRooms.isEmpty {
                    Section("Direct Messages") { ForEach(store.directRooms) { RoomRow(room: $0) } }
                }
            }
            .navigationTitle(store.selectedSpace.flatMap { store.rooms[$0]?.displayName(me: store.me) } ?? "Home")
            .toolbar {
                ToolbarItem { Button { showJoin = true } label: { Image(systemName: "plus") } }
                ToolbarItem { Button { Task { await store.logout() } } label: { Image(systemName: "rectangle.portrait.and.arrow.right") } }
            }
            .alert("Join a room", isPresented: $showJoin) {
                TextField("#room:server or !id:server", text: $joinTarget)
                Button("Join") { let t = joinTarget; joinTarget = ""; Task { await store.join(t) } }
                Button("Cancel", role: .cancel) {}
            }
        } detail: {
            if let id = store.selectedRoom, let r = store.rooms[id], !r.isInvite { RoomView(room: r) }
            else { ContentUnavailableView("Select a room", systemImage: "bubble.left.and.bubble.right") }
        }
        .overlay { if !store.syncing { ProgressView("Syncing…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
    }

    func spaceButton(_ id: String?, _ name: String, _ mxc: String? = nil) -> some View {
        Button { store.selectedSpace = id } label: {
            Avatar(name: name, mxc: mxc, size: 38)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.accentColor, lineWidth: store.selectedSpace == id ? 2 : 0))
        }.buttonStyle(.plain).help(name)
    }
}

struct RoomRow: View {
    @Environment(Store.self) private var store
    let room: RoomState
    var body: some View {
        let name = room.displayName(me: store.me)
        HStack {
            Avatar(name: name, mxc: room.avatarMxc, size: 28)
            Text(name).lineLimit(1).fontWeight(room.notificationCount > 0 ? .semibold : .regular)
            Spacer()
            if room.notificationCount > 0 {
                Text("\(room.notificationCount)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(room.highlightCount > 0 ? Color.red : Color.gray, in: Capsule()).foregroundStyle(.white)
            }
        }
        .tag(room.id)
        .contextMenu { Button("Leave", role: .destructive) { Task { await store.leave(room) } } }
    }
}

// MARK: - Room timeline
struct RoomView: View {
    @Environment(Store.self) private var store
    let room: RoomState
    @State private var draft = ""

    var body: some View {
        let msgs = room.messages
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !room.reachedStart {
                            Button("Load older messages") { Task { await store.loadOlder(room) } }
                                .frame(maxWidth: .infinity).padding()
                        }
                        ForEach(Array(msgs.enumerated()), id: \.element.id) { i, e in
                            MessageRow(room: room, event: e, compact: i > 0 && msgs[i - 1].sender == e.sender &&
                                       e.originServerTs - msgs[i - 1].originServerTs < 300_000)
                                .id(e.id)
                        }
                    }.padding(.horizontal)
                }
                .onChange(of: msgs.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                .onAppear { if let id = msgs.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider()
            if let r = store.replyTo {
                HStack {
                    Text("Replying to \(room.memberName(r.sender)): \(room.body(of: r))").lineLimit(1).font(.caption)
                    Spacer(); Button { store.replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }.padding(.horizontal).padding(.top, 6).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                TextField("Send a message…", text: $draft, axis: .vertical).lineLimit(1...6)
                    .textFieldStyle(.roundedBorder).onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(10)
        }
        .navigationTitle(room.displayName(me: store.me))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: room.id) { if room.timeline.count < 20 { await store.loadOlder(room) } }
    }
    func send() { let t = draft; draft = ""; Task { await store.send(t, in: room) } }
}

struct MessageRow: View {
    @Environment(Store.self) private var store
    let room: RoomState; let event: MatrixEvent; let compact: Bool
    static let quick = ["👍", "❤️", "😂", "🎉", "😮", "🙏"]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if compact { Color.clear.frame(width: 36, height: 1) }
            else { Avatar(name: room.memberName(event.sender),
                          mxc: room.stateEvent("m.room.member", event.sender)?.content["avatar_url"]?.string) }
            VStack(alignment: .leading, spacing: 2) {
                if !compact {
                    HStack(spacing: 6) {
                        Text(room.memberName(event.sender)).bold()
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let rid = event.content["m.relates_to"]?["m.in_reply_to"]?["event_id"]?.string, let orig = room.event(rid) {
                    Text("↩︎ \(room.memberName(orig.sender)): \(room.body(of: orig))").font(.caption).lineLimit(1)
                        .foregroundStyle(.secondary).padding(.leading, 6)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
                }
                content
                reactions
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 1 : 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reply") { store.replyTo = event }
            Menu("React") { ForEach(Self.quick, id: \.self) { k in Button(k) { Task { await store.toggleReaction(k, on: event, in: room) } } } }
            if event.sender == store.me { Button("Delete", role: .destructive) { Task { await store.delete(event, in: room) } } }
        }
    }

    @ViewBuilder var content: some View {
        let body = room.body(of: event)
        switch event.type == "m.room.encrypted" ? "enc" : (event.content["msgtype"]?.string ?? "") {
        case "enc": Text("🔒 Encrypted message (end-to-end encryption isn't supported yet)").italic().foregroundStyle(.secondary)
        case "m.emote": Text("* \(room.memberName(event.sender)) \(body)").italic().textSelection(.enabled)
        case "m.notice": Text(body).foregroundStyle(.secondary).textSelection(.enabled)
        case "m.image":
            if let mxc = event.content["url"]?.string {
                AuthImage(mxc: mxc, size: 300).frame(width: 300, height: 200).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case "m.file", "m.video", "m.audio":
            Label(body, systemImage: "paperclip")
        default:
            Text(LocalizedStringKey(body)).textSelection(.enabled)   // renders inline markdown/links
        }
    }

    @ViewBuilder var reactions: some View {
        if let r = room.reactions[event.eventId], !r.isEmpty {
            HStack {
                ForEach(r.keys.sorted(), id: \.self) { k in
                    let n = r[k]?.count ?? 0
                    if n > 0 {
                        Button { Task { await store.toggleReaction(k, on: event, in: room) } } label: {
                            Text("\(k) \(n)").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(r[k]?[store.me] != nil ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
