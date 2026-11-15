import Foundation
import Observation

/// Per-room state + timeline (the role of matrix-js-sdk's `Room`).
@Observable
final class RoomState: Identifiable {
    let id: String
    var state: [String: MatrixEvent] = [:]          // "type|stateKey"
    var timeline: [MatrixEvent] = []
    var prevBatch: String?
    var notificationCount = 0, highlightCount = 0
    var isInvite = false
    var redacted: Set<String> = []
    var edits: [String: MatrixEvent] = [:]           // target event -> latest edit
    var reactions: [String: [String: [String: String]]] = [:] // target -> key -> sender -> reactionEventId
    var lastReceiptSent: String?
    var reachedStart = false

    init(id: String) { self.id = id }

    func stateEvent(_ type: String, _ key: String = "") -> MatrixEvent? { state["\(type)|\(key)"] }

    var isSpace: Bool { stateEvent("m.room.create")?.content["type"]?.string == "m.space" }
    var topic: String? { stateEvent("m.room.topic")?.content["topic"]?.string }
    var avatarMxc: String? { stateEvent("m.room.avatar")?.content["url"]?.string }
    var canonicalAlias: String? { stateEvent("m.room.canonical_alias")?.content["alias"]?.string }
    var spaceChildren: [String] {
        state.values.filter { $0.type == "m.space.child" && ($0.content["via"]?.array?.isEmpty == false) }
            .compactMap { $0.stateKey }
    }
    var lastActivity: Int64 { timeline.last?.originServerTs ?? 0 }

    func memberName(_ userId: String) -> String {
        stateEvent("m.room.member", userId)?.content["displayname"]?.string ?? userId
    }
    func displayName(me: String) -> String {
        if let n = stateEvent("m.room.name")?.content["name"]?.string, !n.isEmpty { return n }
        if let a = canonicalAlias { return a }
        let others = state.values.filter {
            $0.type == "m.room.member" && $0.stateKey != me &&
            ["join", "invite"].contains($0.content["membership"]?.string ?? "")
        }.compactMap { $0.stateKey }
        if !others.isEmpty { return others.prefix(3).map(memberName).joined(separator: ", ") }
        return "Empty Room"
    }

    // MARK: ingest
    func ingest(_ e: MatrixEvent, prepend: Bool = false) {
        if let k = e.stateKey, !prepend { state["\(e.type)|\(k)"] = e }
        switch e.type {
        case "m.room.redaction":
            if let t = e.redacts ?? e.content["redacts"]?.string { redacted.insert(t) }
        case "m.reaction":
            if let rel = e.content["m.relates_to"], rel["rel_type"]?.string == "m.annotation",
               let t = rel["event_id"]?.string, let k = rel["key"]?.string {
                reactions[t, default: [:]][k, default: [:]][e.sender] = e.eventId
            }
        case "m.room.message":
            if let rel = e.content["m.relates_to"], rel["rel_type"]?.string == "m.replace",
               let t = rel["event_id"]?.string {
                if (edits[t]?.originServerTs ?? 0) <= e.originServerTs { edits[t] = e }
            }
        default: break
        }
        guard !timeline.contains(where: { $0.eventId == e.eventId }) else { return }
        if prepend { timeline.insert(e, at: 0) } else { timeline.append(e) }
    }

    /// Visible message events (edits/redactions/reactions folded away).
    var messages: [MatrixEvent] {
        timeline.filter {
            ($0.type == "m.room.message" || $0.type == "m.room.encrypted") && !redacted.contains($0.eventId)
            && $0.content["m.relates_to"]?["rel_type"]?.string != "m.replace"
        }
    }
    func body(of e: MatrixEvent) -> String {
        var b = edits[e.eventId]?.content["m.new_content"]?["body"]?.string ?? e.content["body"]?.string ?? ""
        if e.content["m.relates_to"]?["m.in_reply_to"] != nil, b.hasPrefix(">") {   // strip reply fallback
            let lines = b.components(separatedBy: "\n")
            if let i = lines.firstIndex(of: "") { b = lines[(i + 1)...].joined(separator: "\n") }
        }
        return b
    }
    func event(_ id: String) -> MatrixEvent? { timeline.first { $0.eventId == id } }
}
