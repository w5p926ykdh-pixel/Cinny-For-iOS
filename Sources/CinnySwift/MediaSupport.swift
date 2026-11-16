import SwiftUI
import UIKit
import WebKit
import AVKit
import PhotosUI
import UniformTypeIdentifiers

enum ImageCache {
    static let images = NSCache<NSString, UIImage>()
    static let blobs = NSCache<NSString, NSData>()
}

// MARK: - API additions (upload / download / authenticated fetch)

extension MatrixAPI {
    private var baseString: String {
        homeserver.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func fetchData(_ url: URL) async -> Data? {
        guard let (data, resp) = try? await URLSession.shared.data(for: authorizedRequest(url)),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    func scaledURL(mxc: String, width: Int, height: Int) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        return URL(string: "\(baseString)/_matrix/client/v1/media/thumbnail/\(mxc.dropFirst(6))?width=\(width)&height=\(height)&method=scale")
    }

    func upload(fileURL: URL, filename: String, mime: String) async throws -> String {
        var comps = URLComponents(string: baseString + "/_matrix/media/v3/upload")!
        comps.queryItems = [URLQueryItem(name: "filename", value: filename)]
        var req = authorizedRequest(comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSON.self, from: data)
        guard (200..<300).contains(status), let uri = json?["content_uri"]?.string else {
            throw MatrixError(status: status, errcode: json?["errcode"]?.string,
                              message: json?["error"]?.string ?? "Upload failed (HTTP \(status))")
        }
        return uri
    }

    func download(mxc: String, filename: String) async throws -> URL {
        guard let url = downloadURL(mxc: mxc) else {
            throw MatrixError(status: 0, errcode: nil, message: "Bad media URL")
        }
        let (tmp, resp) = try await URLSession.shared.download(for: authorizedRequest(url))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw MatrixError(status: status, errcode: nil, message: "Download failed (HTTP \(status))")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appendingPathComponent(safe)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

// MARK: - Store additions (sending media)

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let name = "\(UUID().uuidString).\(received.file.pathExtension)"
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

extension Store {
    func sendMedia(fileURL: URL, filename: String, mime: String, width: Int?, height: Int?, in room: RoomState) async {
        guard let api else { return }
        do {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let mxc = try await api.upload(fileURL: fileURL, filename: filename, mime: mime)
            var info: [String: JSON] = ["mimetype": .string(mime), "size": .number(Double(size))]
            if let w = width, let h = height {
                info["w"] = .number(Double(w))
                info["h"] = .number(Double(h))
            }
            let msgtype: String
            if mime.hasPrefix("image/") { msgtype = "m.image" }
            else if mime.hasPrefix("video/") { msgtype = "m.video" }
            else if mime.hasPrefix("audio/") { msgtype = "m.audio" }
            else { msgtype = "m.file" }
            var content: [String: JSON] = [
                "msgtype": .string(msgtype),
                "body": .string(filename),
                "url": .string(mxc),
                "info": .object(info),
            ]
            if let rt = replyTo {
                content["m.relates_to"] = .object(["m.in_reply_to": .object(["event_id": .string(rt.eventId)])])
                replyTo = nil
            }
            try await api.send(roomId: room.id, type: "m.room.message", content: .object(content))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendPhotoItem(_ item: PhotosPickerItem, in room: RoomState) async {
        let type = item.supportedContentTypes.first
        let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        do {
            if isMovie {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                let ext = movie.url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/mp4"
                await sendMedia(fileURL: movie.url, filename: "video.\(ext)", mime: mime, width: nil, height: nil, in: room)
                return
            }
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            var mime = type?.preferredMIMEType ?? "image/jpeg"
            var ext = type?.preferredFilenameExtension ?? "jpg"
            var payload = data
            let okTypes = ["image/jpeg", "image/png", "image/gif", "image/webp"]
            let image = UIImage(data: data)
            if !okTypes.contains(mime), let jpeg = image?.jpegData(compressionQuality: 0.9) {
                payload = jpeg; mime = "image/jpeg"; ext = "jpg"
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try payload.write(to: dest)
            let w = image.map { Int($0.size.width) }
            let h = image.map { Int($0.size.height) }
            await sendMedia(fileURL: dest, filename: "image.\(ext)", mime: mime, width: w, height: h, in: room)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendPickedFile(_ url: URL, in room: RoomState) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            var w: Int? = nil
            var h: Int? = nil
            if mime.hasPrefix("image/"), let img = UIImage(contentsOfFile: dest.path) {
                w = Int(img.size.width)
                h = Int(img.size.height)
            }
            await sendMedia(fileURL: dest, filename: url.lastPathComponent, mime: mime, width: w, height: h, in: room)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendGIF(from url: URL, width: Int?, height: Int?, in room: RoomState) async {
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
            try FileManager.default.moveItem(at: tmp, to: dest)
            await sendMedia(fileURL: dest, filename: "animated.gif", mime: "image/gif", width: width, height: height, in: room)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Animated GIF (WebKit animates GIFs natively)

struct GIFView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.backgroundColor = .clear
        web.load(data, mimeType: "image/gif", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Full-screen viewer (images, GIFs, video, files)

struct ViewerItem: Identifiable {
    let id = UUID()
    let mxc: String
    let filename: String
    let mime: String
}

struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                if player == nil {
                    let p = AVPlayer(url: url)
                    player = p
                    p.play()
                }
            }
            .onDisappear { player?.pause() }
    }
}

struct MediaViewer: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: ViewerItem
    @State private var fileURL: URL?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let fileURL { ShareLink(item: fileURL) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let url = fileURL {
            if item.mime.hasPrefix("video/") || item.mime.hasPrefix("audio/") {
                PlayerView(url: url)
            } else if item.mime == "image/gif", let d = try? Data(contentsOf: url) {
                GIFView(data: d)
            } else if item.mime.hasPrefix("image/"), let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill").font(.system(size: 56))
                    Text(item.filename)
                    Text("Use the share button to save or open this file.").font(.caption).foregroundStyle(.secondary)
                }.foregroundStyle(.white)
            }
        } else if failed {
            Text("Couldn't load this file").foregroundStyle(.white)
        } else {
            ProgressView().tint(.white)
        }
    }

    private func load() async {
        guard let api = store.api else { return }
        do { fileURL = try await api.download(mxc: item.mxc, filename: item.filename) }
        catch { failed = true }
    }
}

// MARK: - GIF picker (Giphy search; needs a free API key)

struct GIFResult: Identifiable {
    let id: String
    let previewURL: URL
    let sendURL: URL
    let width: Int?
    let height: Int?
}

struct GIFPicker: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("giphyAPIKey") private var apiKey = ""
    @State private var keyDraft = ""
    @State private var query = ""
    @State private var results: [GIFResult] = []
    @State private var loading = false
    let onPick: (GIFResult) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if apiKey.isEmpty { keySetup } else { grid }
            }
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if !apiKey.isEmpty { Button("Change key") { apiKey = ""; results = [] } }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var keySetup: some View {
        VStack(spacing: 14) {
            Text("GIF search uses Giphy. Create a free API key at developers.giphy.com and paste it here.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
            TextField("Giphy API key", text: $keyDraft)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.composer, in: RoundedRectangle(cornerRadius: 10))
            Button("Save") { apiKey = keyDraft.trimmingCharacters(in: .whitespaces) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(keyDraft.isEmpty)
        }.padding(24)
    }

    private var grid: some View {
        ScrollView {
            if loading && results.isEmpty { ProgressView().padding() }
            if !loading && results.isEmpty {
                Text("No GIFs found. If this keeps happening, check your API key.")
                    .foregroundStyle(Theme.muted).padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], spacing: 6) {
                ForEach(results) { gif in
                    Button {
                        onPick(gif)
                        dismiss()
                    } label: {
                        AsyncImage(url: gif.previewURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.1)
                        }
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.padding(8)
        }
        .searchable(text: $query, prompt: "Search GIFs")
        .onSubmit(of: .search) { Task { await search() } }
        .task { await search() }
    }

    private func search() async {
        guard !apiKey.isEmpty else { return }
        loading = true
        defer { loading = false }
        let endpoint = query.isEmpty ? "https://api.giphy.com/v1/gifs/trending" : "https://api.giphy.com/v1/gifs/search"
        guard var comps = URLComponents(string: endpoint) else { return }
        var items = [URLQueryItem(name: "api_key", value: apiKey),
                     URLQueryItem(name: "limit", value: "30"),
                     URLQueryItem(name: "rating", value: "pg-13")]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        comps.queryItems = items
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONDecoder().decode(JSON.self, from: data),
              let arr = json["data"]?.array else { results = []; return }
        results = arr.compactMap { (item: JSON) -> GIFResult? in
            guard let id = item["id"]?.string,
                  let p = item["images"]?["fixed_width"]?["url"]?.string,
                  let o = item["images"]?["original"]?["url"]?.string,
                  let pu = URL(string: p), let ou = URL(string: o) else { return nil }
            let w = Int(item["images"]?["original"]?["width"]?.string ?? "")
            let h = Int(item["images"]?["original"]?["height"]?.string ?? "")
            return GIFResult(id: id, previewURL: pu, sendURL: ou, width: w, height: h)
        }
    }
}
