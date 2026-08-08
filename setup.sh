#!/bin/bash

echo "Creating Claude Code context files..."

cat << 'FILE' > CLAUDE.md
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
FILE

cat << 'FILE' > PRD.md
# PRD: SentryGuard (v1.1)

## Core Features
1. **Scarecrow Charge-Guard:**
   - Triggers 2 horn honks + 3 high-beam flashes when `ChargePortLatch` shifts to `Disengaged` while door locks are `Engaged`.
   - Max execution latency: < 2.5s.
2. **Critical Unplug Alert Pipeline:**
   - APNs payload configured with iOS Critical Alerts (`com.apple.developer.usernotifications.critical-alerts`) to bypass Silent/Do Not Disturb mode.
   - Twilio SMS/Voice call fallback if push unacknowledged within 30 seconds.
3. **Read-Only Status Widgets:**
   - Displays Battery %, Lock State, and Sentry Mode Status.
   - Tapping any widget opens the main app. Zero direct controls on the widget.
4. **Safety-Interlocked Commands:**
   - In-app action trigger -> Confirmation Modal -> Face ID Check -> Signed Tesla API Command.
5. **Smart Utility Reminders:**
   - "Forgot to Plug In" nightly alert (Home location, > 9:00 PM, SoC < 60%, Unplugged).
   - Geofenced Charge Limits (80% Home, 90%/100% away).
FILE

cat << 'FILE' > ARCHITECTURE.md
# Technical Architecture

## Data Flow
[Vehicle] --(WebSocket Telemetry)--> [Cloudflare Worker] --(APNs Critical)--> [iOS App]
[iOS App] --(Face ID Verified)-----> [Tesla Fleet API]  --(Vehicle Cmd)-----> [Vehicle]

## Key System Components

### 1. Security & Keys (`Services/SecurityManager.swift`)
- Generates `secp256r1` ECDSA key pair inside iOS Secure Enclave.
- Exports public key for registration at `https://yourdomain.com/.well-known/appspecific/com.tesla.3p.public-key.pem`.
- Manages `LocalAuthentication` context for Face ID checks.

### 2. Keychain Storage (`Services/KeychainService.swift`)
- Stores `accessToken`, `refreshToken`, and `privateKey`.

### 3. Tesla API Client (`Services/TeslaApiClient.swift`)
- `authenticate(code: String)` -> Exchanges OAuth code for tokens.
- `executeCommand(vin: String, command: VehicleCommand)` -> Validates Face ID, signs payload, sends `POST /api/1/vehicles/{vin}/command/{cmd}`.

### 4. Widget Extension (`SentryGuardWidget/`)
- Reads cached vehicle state from shared App Group `UserDefaults(suiteName: "group.com.sentryguard.app")`.
- Reloads timeline via `WidgetCenter.shared.reloadAllTimelines()`.
FILE

cat << 'FILE' > TASKS.md
# Execution Tasks

## Phase 1: Core App & Authentication
- [ ] Task 1.1: Initialize Xcode project with Swift 6, SwiftUI, and App Group capabilities.
- [ ] Task 1.2: Build `KeychainService.swift` to securely store and read OAuth tokens.
- [ ] Task 1.3: Implement `TeslaOAuthView.swift` using `ASWebAuthenticationSession` for OAuth 2.0 login.
- [ ] Task 1.4: Build `SecurityManager.swift` using `LocalAuthentication` for Face ID verification.

## Phase 2: Vehicle Command Engine & Safety Interlocks
- [ ] Task 2.1: Build `TeslaApiClient.swift` with typed `VehicleCommand` enums (Honk, Flash, Unlock, Lock).
- [ ] Task 2.2: Implement `ConfirmationModalView.swift` that forces user confirmation + Face ID before calling `TeslaApiClient`.
- [ ] Task 2.3: Build Main Dashboard UI displaying vehicle status card and control buttons.

## Phase 3: Read-Only WidgetKit Extension
- [ ] Task 3.1: Add a Widget Extension target to the Xcode workspace.
- [ ] Task 3.2: Configure App Group shared storage between Main App and Widget Extension.
- [ ] Task 3.3: Implement Read-Only `LockScreenWidgetView.swift` showing Battery %, Sentry Status, and Lock State.

## Phase 4: Serverless Backend (Cloudflare Worker)
- [ ] Task 4.1: Initialize Cloudflare Worker project for Tesla Fleet Telemetry WebSockets.
- [ ] Task 4.2: Add logic to process `ChargePortLatch` disengage events and send APNs push payloads.
FILE

echo "Done! CLAUDE.md, PRD.md, ARCHITECTURE.md, and TASKS.md have been generated."
