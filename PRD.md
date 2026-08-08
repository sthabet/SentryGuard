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
