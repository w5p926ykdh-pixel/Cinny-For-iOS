import SwiftUI

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

enum Theme {
    static let rail = Color(hex: 0x1A1024)
    static let sidebar = Color(hex: 0x2B1740)
    static let chat = Color(hex: 0x28285A)
    static let bubble = Color(hex: 0x363C78)
    static let ownBubble = Color(hex: 0x7B5FB3)
    static let composer = Color(hex: 0x2F3470)
    static let accent = Color(hex: 0x9C8AD6)
    static let selected = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.6)

    static func userColor(_ id: String) -> Color {
        let palette: [UInt32] = [0xE879F9, 0x67E8F9, 0xFDBA74, 0x86EFAC, 0xF9A8D4, 0xA5B4FC, 0xFCD34D, 0x5EEAD4]
        var h = 0
        for u in id.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0xFFFF }
        return Color(hex: palette[h % palette.count])
    }
}
