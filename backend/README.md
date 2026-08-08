# SentryGuard Worker

Cloudflare Worker backend for SentryGuard. Handles Tesla Fleet Telemetry webhook
ingestion, Tesla partner-domain registration, and hosting the public key Tesla's
servers fetch to verify domain ownership.

## Setup

```sh
npm install
cp .dev.vars.example .dev.vars   # fill in real values for local dev; never commit this file
```

## Commands

| Command | Purpose |
|---|---|
| `npm run dev` | Run the worker locally via `wrangler dev` |
| `npm test` | Run the Vitest suite |
| `npm run typecheck` | Type-check with `tsc --noEmit` |
| `npm run deploy` | Deploy via `wrangler deploy` |

## Secrets

Set these in production with `wrangler secret put <NAME>` — never in `wrangler.toml`:

- `TESLA_CLIENT_ID` / `TESLA_CLIENT_SECRET` — Tesla Developer app credentials, used for
  the `client_credentials` grant when registering the partner domain.
- `TESLA_PUBLIC_KEY_PEM` — the PEM served at
  `/.well-known/appspecific/com.tesla.3p.public-key.pem`.
- `APNS_KEY_P8` — contents of the `.p8` Auth Key from Apple Developer (Certificates,
  Identifiers & Profiles > Keys), PKCS#8 PEM format.
- `APNS_KEY_ID` — the 10-character Key ID for that `.p8` key.
- `APNS_TEAM_ID` — your Apple Developer Team ID.
- `APNS_BUNDLE_ID` — the iOS app's bundle identifier (`com.sentryguard.app`), sent as
  the `apns-topic` header.
- `APNS_DEVICE_TOKEN` — the target device's APNs token. Single-user MVP: one worker
  alerts one device. A multi-device version would replace this with a device-token
  registry (e.g. Workers KV) instead of a single secret.

## Routes

- `GET /health` — status + worker version.
- `GET /.well-known/appspecific/com.tesla.3p.public-key.pem` — serves `TESLA_PUBLIC_KEY_PEM`.
- `POST /api/partner-keys` — registers this worker's domain with Tesla's Fleet API
  (`POST /api/1/partner_accounts`) using the `client_credentials` grant.
- `POST /api/telemetry` — receives a Tesla Fleet Telemetry webhook event (a `data` array
  of changed `{key, value}` fields), validates it, and — only when the SAME message
  confirms both `ChargeState_ChargePortLatch: "Disengaged"` and
  `ChargeState_ChargingState: "Charging"` — dispatches a critical, DND-bypassing APNs
  push alert. The webhook is always acknowledged with 200 even if the APNs push itself
  fails, so Tesla never retries an already-valid event over a downstream push failure.
