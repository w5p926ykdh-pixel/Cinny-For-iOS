import Foundation
import Observation
import Security

enum Keychain {
    static let key = "cinny-swift.session"
    static func save(_ s: Session) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
    }
    static func load() -> Session? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
    }
}

/// App-wide state (Cinny's jotai atoms + MatrixClient lifecycle, merged).
@MainActor @Observable
final class Store {
    var session: Session?
    var rooms: [String: RoomState] = [:]
    var directIds: Set<String> = []
    var selectedSpace: String?          // nil = Home
    var selectedRoom: String?
    var replyTo: MatrixEvent?
    var syncing = false
    var errorMessage: String?

    private var since: String?
    private var syncTask: Task<Void, Never>?
    var api: MatrixAPI? { session.map { MatrixAPI(homeserver: $0.homeserver, token: $0.accessToken) } }
    var me: String { session?.userId ?? "" }

    init() {
        if let s = Keychain.load() { session = s; startSync() }
    }

    // MARK: auth
    func login(server: String, user: String, password: String) async {
        errorMessage = nil
        do {
            let base = await MatrixAPI.discover(server)
            let s = try await MatrixAPI(homeserver: base).login(user: user, password: password)
            Keychain.save(s); session = s; startSync()
        } catch { errorMessage = error.localizedDescription }
    }
    func logout() async {
        syncTask?.cancel()
        await api?.logout()
        Keychain.clear()
        session = nil; rooms = [:]; since = nil; selectedRoom = nil; selectedSpace = nil
    }

    // MARK: sync loop
    func startSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while let self, !Task.isCancelled, let api = self.api {
                do {
                    let r = try await api.sync(since: self.since, timeout: self.since == nil ? 0 : 30_000)
                    self.apply(r); self.since = r.nextBatch; self.syncing = true
                } catch let e as MatrixError where e.status == 401 {
                    await self.logout(); return
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func room(_ id: String) -> RoomState {
        if let r = rooms[id] { return r }
        let r = RoomState(id: id); rooms[id] = r; return r
    }

    private func apply(_ r: SyncResponse) {
        for e in r.accountData?.events ?? [] where e.type == "m.direct" {
            directIds = Set((e.content.object ?? [:]).values.flatMap { $0.array ?? [] }.compactMap(\.string))
        }
        for (id, j) in r.rooms?.join ?? [:] {
            let rs = room(id)
            rs.isInvite = false
            j.state?.events?.forEach { rs.state["\($0.type)|\($0.stateKey ?? "")"] = $0 }
            if rs.prevBatch == nil || j.timeline?.limited == true, let pb = j.timeline?.prevBatch { 
                if rs.timeline.isEmpty { rs.prevBatch = pb }
            }
            j.timeline?.events?.forEach { rs.ingest($0) }
            rs.notificationCount = j.unread?.notificationCount ?? rs.notificationCount
            rs.highlightCount = j.unread?.highlightCount ?? rs.highlightCount
            if selectedRoom == id { markRead(rs) }
        }
        for (id, inv) in r.rooms?.invite ?? [:] {
            let rs = room(id); rs.isInvite = true
            inv.inviteState?.events?.forEach { rs.state["\($0.type)|\($0.stateKey ?? "")"] = $0 }
        }
        for id in (r.rooms?.leave ?? [:]).keys {
            rooms[id] = nil
            if selectedRoom == id { selectedRoom = nil }
        }
    }

    // MARK: derived lists (Home / Spaces / DMs — mirrors Cinny's room-list state)
    var spaces: [RoomState] {
        rooms.values.filter { $0.isSpace && !$0.isInvite }
            .sorted { $0.displayName(me: me).localizedCaseInsensitiveCompare($1.displayName(me: me)) == .orderedAscending }
    }
    var invites: [RoomState] { rooms.values.filter(\.isInvite) }
    private var allSpaceChildren: Set<String> { Set(spaces.flatMap(\.spaceChildren)) }

    /// Rooms in the selected space, or Home (rooms that are in no space).
    var visibleRooms: [RoomState] {
        let joined = rooms.values.filter { !$0.isInvite && !$0.isSpace && !directIds.contains($0.id) }
        let list: [RoomState]
        if let s = selectedSpace, let sp = rooms[s] {
            let kids = Set(sp.spaceChildren); list = joined.filter { kids.contains($0.id) }
        } else { let inSpace = allSpaceChildren; list = joined.filter { !inSpace.contains($0.id) } }
        return list.sorted { $0.lastActivity > $1.lastActivity }
    }
    var directRooms: [RoomState] {
        rooms.values.filter { !$0.isInvite && directIds.contains($0.id) }.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: actions
    func markRead(_ r: RoomState) {
        guard let last = r.timeline.last?.eventId, r.lastReceiptSent != last, let api else { return }
        r.lastReceiptSent = last; r.notificationCount = 0; r.highlightCount = 0
        Task { await api.sendReadReceipt(roomId: r.id, eventId: last) }
    }
    func select(_ id: String) {
        selectedRoom = id; replyTo = nil
        if let r = rooms[id] { markRead(r) }
    }
    func loadOlder(_ r: RoomState) async {
        guard let api, !r.reachedStart else { return }
        do {
            let res = try await api.messages(roomId: r.id, from: r.prevBatch)
            for e in res.chunk { r.ingest(e, prepend: true) }  // chunk is newest-first, so this ends up chronological
            r.prevBatch = res.end
            if res.end == nil || res.chunk.isEmpty { r.reachedStart = true }
        } catch { errorMessage = error.localizedDescription }
    }
    func send(_ text: String, in r: RoomState) async {
        guard let api, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var content: [String: JSON]
        if text.hasPrefix("/me ") { content = ["msgtype": .string("m.emote"), "body": .string(String(text.dropFirst(4)))] }
        else { content = ["msgtype": .string("m.text"), "body": .string(text)] }
        if let rt = replyTo {
            content["m.relates_to"] = .object(["m.in_reply_to": .object(["event_id": .string(rt.eventId)])])
            replyTo = nil
        }
        do { try await api.send(roomId: r.id, type: "m.room.message", content: .object(content)) }
        catch { errorMessage = error.localizedDescription }
    }
    func toggleReaction(_ key: String, on e: MatrixEvent, in r: RoomState) async {
        guard let api else { return }
        do {
            if let mine = r.reactions[e.eventId]?[key]?[me] {
                try await api.redact(roomId: r.id, eventId: mine)
                r.reactions[e.eventId]?[key]?[me] = nil
            } else {
                let content: JSON = .object(["m.relates_to": .object([
                    "rel_type": .string("m.annotation"), "event_id": .string(e.eventId), "key": .string(key)])])
                let id = try await api.send(roomId: r.id, type: "m.reaction", content: content)
                r.reactions[e.eventId, default: [:]][key, default: [:]][me] = id
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func delete(_ e: MatrixEvent, in r: RoomState) async {
        do { try await api?.redact(roomId: r.id, eventId: e.eventId); r.redacted.insert(e.eventId) }
        catch { errorMessage = error.localizedDescription }
    }
    func join(_ idOrAlias: String) async {
        do { try await api?.join(idOrAlias) } catch { errorMessage = error.localizedDescription }
    }
    func leave(_ r: RoomState) async {
        do { try await api?.leave(roomId: r.id); rooms[r.id] = nil; if selectedRoom == r.id { selectedRoom = nil } }
        catch { errorMessage = error.localizedDescription }
    }
}
