# Execution Tasks

## Phase 1: Core App & Authentication
- [x] Task 1.1: Initialize Xcode project with Swift 6, SwiftUI, and App Group capabilities.
- [x] Task 1.2: Build `KeychainService.swift` to securely store and read OAuth tokens.
- [x] Task 1.3: Implement `TeslaOAuthView.swift` using `ASWebAuthenticationSession` for OAuth 2.0 login.
- [x] Task 1.4: Build `SecurityManager.swift` using `LocalAuthentication` for Face ID verification.

## Phase 2: Vehicle Command Engine & Safety Interlocks
- [x] Task 2.1: Build `TeslaApiClient.swift` with typed `VehicleCommand` enums (Honk, Flash, Unlock, Lock).
- [x] Task 2.2: Implement `ConfirmationModalView.swift` that forces user confirmation + Face ID before calling `TeslaApiClient`.
- [x] Task 2.3: Build Main Dashboard UI displaying vehicle status card and control buttons.

## Phase 3: Read-Only WidgetKit Extension
- [x] Task 3.1: Add a Widget Extension target to the Xcode workspace.
- [x] Task 3.2: Configure App Group shared storage between Main App and Widget Extension.
- [x] Task 3.3: Implement Read-Only `LockScreenWidgetView.swift` showing Battery %, Sentry Status, and Lock State.

## Phase 4: Settings & Security Management
- [x] Task 4.1: Build `SettingsView.swift` and `SettingsViewModel.swift` for account management and security controls (VIN/session/app version display, biometric strictness toggle, clear cache, log out).
- [x] Task 4.2: Wire the root navigation flow (`ContentView.swift` + `SentryGuardApp.swift`) — auth-state-driven switch between `TeslaOAuthView` and the main `TabView` (Dashboard + Settings), with `scenePhase`-triggered background refresh and WidgetKit timeline reloads.

## Phase 5: Serverless Backend (Cloudflare Worker)
- [x] Task 5.1: Initialize Cloudflare Worker project for Tesla Fleet Telemetry WebSockets.
- [x] Task 5.2: Add logic to process `ChargePortLatch` disengage events and send APNs push payloads.
