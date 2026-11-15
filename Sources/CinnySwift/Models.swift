import Foundation

// Loosely-typed JSON, used for Matrix event content (like matrix-js-sdk's `IContent`).
enum JSON: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSON]), array([JSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(key: String) -> JSON? { if case .object(let o) = self { return o[key] }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
}

struct MatrixEvent: Codable, Identifiable, Hashable {
    var eventId: String
    var type: String
    var sender: String
    var originServerTs: Int64
    var content: JSON
    var stateKey: String?
    var redacts: String?
    var id: String { eventId }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", type, sender, content, redacts
        case originServerTs = "origin_server_ts", stateKey = "state_key"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        eventId = (try? c.decode(String.self, forKey: .eventId)) ?? UUID().uuidString // stripped invite state has none
        type = try c.decode(String.self, forKey: .type)
        sender = (try? c.decode(String.self, forKey: .sender)) ?? ""
        originServerTs = (try? c.decode(Int64.self, forKey: .originServerTs)) ?? 0
        content = (try? c.decode(JSON.self, forKey: .content)) ?? .object([:])
        stateKey = try? c.decode(String.self, forKey: .stateKey)
        redacts = try? c.decode(String.self, forKey: .redacts)
    }
    var date: Date { Date(timeIntervalSince1970: Double(originServerTs) / 1000) }
}

// MARK: - /sync

struct EventList: Decodable { var events: [MatrixEvent]? }
struct SyncTimeline: Decodable {
    var events: [MatrixEvent]?; var prevBatch: String?; var limited: Bool?
    enum CodingKeys: String, CodingKey { case events, limited, prevBatch = "prev_batch" }
}
struct UnreadCounts: Decodable {
    var notificationCount: Int?; var highlightCount: Int?
    enum CodingKeys: String, CodingKey { case notificationCount = "notification_count", highlightCount = "highlight_count" }
}
struct JoinedRoom: Decodable {
    var state: EventList?; var timeline: SyncTimeline?; var unread: UnreadCounts?
    enum CodingKeys: String, CodingKey { case state, timeline, unread = "unread_notifications" }
}
struct InvitedRoom: Decodable {
    var inviteState: EventList?
    enum CodingKeys: String, CodingKey { case inviteState = "invite_state" }
}
struct SyncRooms: Decodable {
    var join: [String: JoinedRoom]?; var invite: [String: InvitedRoom]?; var leave: [String: JSON]?
}
struct SyncResponse: Decodable {
    var nextBatch: String; var rooms: SyncRooms?; var accountData: EventList?
    enum CodingKeys: String, CodingKey { case nextBatch = "next_batch", rooms, accountData = "account_data" }
}
struct MessagesResponse: Decodable {
    var chunk: [MatrixEvent]; var end: String?
}

struct Session: Codable {
    var homeserver: URL; var userId: String; var deviceId: String; var accessToken: String
}
