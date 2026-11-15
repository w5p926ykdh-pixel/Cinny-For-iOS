# CinnySwift

A native SwiftUI Matrix client modelled on Cinny (iOS 17+ / macOS 14+, no dependencies).

Run: `swift run` on macOS, or create a new Multiplatform App in Xcode and drop in `Sources/CinnySwift/*.swift`
(delete the template's @main).

Implemented: homeserver discovery + password login (Keychain), incremental /sync, Home/Spaces/DMs,
invites, join/leave, timeline with back-pagination, edits, redactions, replies, reactions, unread/highlight
badges, read receipts, authenticated media avatars/images, `/me`.

Not yet ported (needs a Rust crypto binding or large UI work): E2EE, SSO/OIDC login, rich-text/HTML
rendering and the Slate editor, file upload, emoji/sticker packs, calls (Element Call), room/space settings,
search, device verification & key backup, push notifications, threads.
