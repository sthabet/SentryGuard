# CLAUDE.md - Project Rules & Conventions

## Project Summary
Native iOS app (SwiftUI) and serverless backend (Cloudflare Workers) providing active security deterrence ("Scarecrow Mode"), critical unplug alerts, and zero-battery-drain read-only Lock Screen widgets for Tesla vehicles.

## Tech Stack
- **iOS Client:** Swift 6, SwiftUI, WidgetKit, UserNotifications, LocalAuthentication, Security (Keychain).
- **Backend:** Node.js / TypeScript on Cloudflare Workers.
- **Tesla Protocol:** Tesla Fleet API (OAuth 2.0) + Fleet Telemetry (WebSockets, secp256r1 ECDSA signing).

## Non-Negotiable Architecture Rules
1. **Zero-Trouble Widgets:** Lock Screen & Home Screen widgets MUST BE 100% READ-ONLY. Widgets display cached data only. NEVER place action buttons on widgets.
2. **Mandatory Confirmation & Face ID:** EVERY vehicle command in the main app MUST display a confirmation dialog AND pass `LocalAuthentication` (Face ID / Touch ID) BEFORE executing the API call.
3. **No Vehicle Polling:** NEVER poll the car over HTTP in background tasks. All status updates arrive passively via WebSocket telemetry pushed to the backend.
4. **Keychain Storage:** OAuth tokens, refresh tokens, and private keys MUST be stored in the iOS Keychain (`SecItemAdd`), NEVER in `UserDefaults`.

## Coding Standards
- Use modern SwiftUI with `@Observable` (Observation framework) for state management.
- Keep UI components small, modular, and reusable in `Views/Components/`.
- Handle all API network calls asynchronously using `async/await` and typed `Result` enums.
