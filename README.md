# Nováre Phone

The official softphone app of **Nóváre Telecom, a division of Novare Digital Corp** — [novaretelecom.com](https://novaretelecom.com). iOS first (native Swift, SwiftUI + CallKit + PushKit on the Linphone SDK), Android next.

## How it works

- Sign in by scanning a QR code from your **My Phone** portal. The app ships with **no** server addresses, ports, URLs, or credentials — everything arrives in the QR payload at sign-in, so the app works against any Nóváre PBX server, current or future, on any port.
- Incoming calls ring even when the app is closed: the PBX push gateway sends an APNs VoIP push, and CallKit presents the native call screen.
- Calls, mute, hold, DTMF, and one-touch voicemail (*97).

## Building

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
xcodegen generate
xcodebuild -project NovarePhone.xcodeproj -scheme NovarePhone -sdk iphonesimulator build
```

The `linphonesw` SDK resolves via Swift Package Manager from gitlab.linphone.org (large first fetch).

## License

The source code is licensed under the **GNU Affero General Public License v3** — see [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

The Nóvare names, app icon, and logos are **trademarks of Novare Digital Corp and are NOT covered by the code license** — see [BRAND-ASSETS-LICENSE](BRAND-ASSETS-LICENSE). Derivative apps must ship under their own branding.
