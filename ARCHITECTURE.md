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
