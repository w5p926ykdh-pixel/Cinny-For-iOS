import Foundation

struct MatrixError: LocalizedError {
    var status: Int; var errcode: String?; var message: String
    var errorDescription: String? { message }
}

/// Thin Client-Server API wrapper (replaces matrix-js-sdk's HTTP layer).
struct MatrixAPI {
    var homeserver: URL
    var token: String?

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    /// .well-known discovery, like Cinny's autoDiscovery step.
    static func discover(_ input: String) async -> URL {
        var host = input.trimmingCharacters(in: .whitespaces)
        if !host.hasPrefix("http") { host = "https://" + host }
        if let u = URL(string: host + "/.well-known/matrix/client"),
           let (data, _) = try? await URLSession.shared.data(from: u),
           let json = try? JSONDecoder().decode(JSON.self, from: data),
           let s = json["m.homeserver"]?["base_url"]?.string, let url = URL(string: s) { return url }
        return URL(string: host)!
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                       body: Encodable? = nil, as: T.Type = T.self) async throws -> T {
        var comps = URLComponents(string: homeserver.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 60
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let j = try? JSONDecoder().decode(JSON.self, from: data)
            throw MatrixError(status: status, errcode: j?["errcode"]?.string,
                              message: j?["error"]?.string ?? "HTTP \(status)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private struct AnyEncodable: Encodable {
        let v: Encodable
        init(_ v: Encodable) { self.v = v }
        func encode(to e: Encoder) throws { try v.encode(to: e) }
    }
    private struct Empty: Decodable {}

    // MARK: Auth
    func login(user: String, password: String) async throws -> Session {
        let body: JSON = .object([
            "type": .string("m.login.password"),
            "identifier": .object(["type": .string("m.id.user"), "user": .string(user)]),
            "password": .string(password),
            "initial_device_display_name": .string("Cinny Swift"),
        ])
        let r: JSON = try await request("POST", "/_matrix/client/v3/login", body: body)
        guard let uid = r["user_id"]?.string, let tok = r["access_token"]?.string else {
            throw MatrixError(status: 0, errcode: nil, message: "Malformed login response")
        }
        return Session(homeserver: homeserver, userId: uid, deviceId: r["device_id"]?.string ?? "", accessToken: tok)
    }
    func logout() async { _ = try? await request("POST", "/_matrix/client/v3/logout", body: JSON.object([:]), as: Empty.self) }

    // MARK: Sync & history
    func sync(since: String?, timeout: Int) async throws -> SyncResponse {
        var q = ["timeout": String(timeout),
                 "filter": #"{"room":{"timeline":{"limit":30}}}"#]
        if let since { q["since"] = since }
        return try await request("GET", "/_matrix/client/v3/sync", query: q)
    }
    func messages(roomId: String, from: String?, limit: Int = 30) async throws -> MessagesResponse {
        var q = ["dir": "b", "limit": String(limit)]
        if let from { q["from"] = from }
        return try await request("GET", "/_matrix/client/v3/rooms/\(Self.enc(roomId))/messages", query: q)
    }

    // MARK: Actions
    @discardableResult
    func send(roomId: String, type: String, content: JSON) async throws -> String {
        let txn = UUID().uuidString
        let r: JSON = try await request("PUT", "/_matrix/client/v3/rooms/\(Self.enc(roomId))/send/\(Self.enc(type))/\(txn)", body: content)
        return r["event_id"]?.string ?? ""
    }
    func redact(roomId: String, eventId: String) async throws {
        let txn = UUID().uuidString
        let _: JSON = try await request("PUT", "/_matrix/client/v3/rooms/\(Self.enc(roomId))/redact/\(Self.enc(eventId))/\(txn)", body: JSON.object([:]))
    }
    func sendReadReceipt(roomId: String, eventId: String) async {
        let _: JSON? = try? await request("POST", "/_matrix/client/v3/rooms/\(Self.enc(roomId))/receipt/m.read/\(Self.enc(eventId))", body: JSON.object([:]))
    }
    func join(_ roomIdOrAlias: String) async throws {
        let _: JSON = try await request("POST", "/_matrix/client/v3/join/\(Self.enc(roomIdOrAlias))", body: JSON.object([:]))
    }
    func leave(roomId: String) async throws {
        let _: JSON = try await request("POST", "/_matrix/client/v3/rooms/\(Self.enc(roomId))/leave", body: JSON.object([:]))
    }

    // MARK: Media (authenticated media, as Cinny's useMediaAuthentication does)
    func thumbnailURL(mxc: String, size: Int) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        let rest = mxc.dropFirst(6)
        return URL(string: "\(homeserver.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/_matrix/client/v1/media/thumbnail/\(rest)?width=\(size)&height=\(size)&method=crop")
    }
    func downloadURL(mxc: String) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        return URL(string: "\(homeserver.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/_matrix/client/v1/media/download/\(mxc.dropFirst(6))")
    }
}
