export interface Env {
  TESLA_FLEET_API_BASE_URL: string;
  TESLA_AUTH_BASE_URL: string;
  TESLA_CLIENT_ID: string;
  TESLA_CLIENT_SECRET: string;
  TESLA_PUBLIC_KEY_PEM: string;
  // APNs — see README for how each of these is obtained/configured.
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  /// Single-user MVP: the one iOS device to alert. A future multi-device version would
  /// replace this with a device-token registry (e.g. Workers KV) keyed by VIN/account.
  APNS_DEVICE_TOKEN: string;
}

const WORKER_VERSION = "1.0.0";
const PUBLIC_KEY_PATH = "/.well-known/appspecific/com.tesla.3p.public-key.pem";

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return handleHealth();
    }

    if (request.method === "GET" && url.pathname === PUBLIC_KEY_PATH) {
      return handlePublicKey(env);
    }

    if (request.method === "POST" && url.pathname === "/api/partner-keys") {
      return handlePartnerKeyRegistration(env);
    }

    if (request.method === "POST" && url.pathname === "/api/telemetry") {
      return handleTelemetry(request, env);
    }

    return jsonResponse({ error: "Not Found" }, 404);
  },
};

// MARK: - Response helper

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// MARK: - GET /health

function handleHealth(): Response {
  return jsonResponse({ status: "ok", version: WORKER_VERSION });
}

// MARK: - GET /.well-known/appspecific/com.tesla.3p.public-key.pem
//
// Tesla's servers fetch this directly to verify domain ownership before Fleet API /
// Virtual Key pairing requests from that domain are trusted.

function handlePublicKey(env: Env): Response {
  if (!env.TESLA_PUBLIC_KEY_PEM) {
    return jsonResponse({ error: "Public key not configured on this worker." }, 500);
  }
  return new Response(env.TESLA_PUBLIC_KEY_PEM, {
    status: 200,
    headers: { "Content-Type": "application/x-pem-file" },
  });
}

// MARK: - POST /api/partner-keys
//
// Registers this worker's domain with Tesla as a partner account
// (POST /api/1/partner_accounts) using the client_credentials grant, per Tesla's
// Fleet API third-party developer onboarding flow.

interface TeslaTokenResponse {
  access_token?: string;
}

interface PartnerAccountResponse {
  response?: unknown;
}

async function handlePartnerKeyRegistration(env: Env): Promise<Response> {
  if (!env.TESLA_CLIENT_ID || !env.TESLA_CLIENT_SECRET) {
    return jsonResponse(
      { error: "Tesla partner credentials are not configured on this worker." },
      503
    );
  }

  let accessToken: string;
  try {
    accessToken = await fetchPartnerAccessToken(env);
  } catch (error) {
    return jsonResponse(
      { error: "Failed to obtain a Tesla partner access token.", details: describeError(error) },
      502
    );
  }

  const domain = new URL(env.TESLA_FLEET_API_BASE_URL).hostname;
  let registerResponse: Response;
  try {
    registerResponse = await fetch(`${env.TESLA_FLEET_API_BASE_URL}/api/1/partner_accounts`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ domain }),
    });
  } catch (error) {
    return jsonResponse(
      { error: "Network error contacting Tesla's partner registration endpoint.", details: describeError(error) },
      502
    );
  }

  const data = (await registerResponse.json().catch(() => ({}))) as PartnerAccountResponse;

  if (!registerResponse.ok) {
    return jsonResponse(
      { error: "Tesla rejected the partner domain registration.", details: data },
      502
    );
  }

  return jsonResponse({ status: "registered", domain, response: data.response });
}

async function fetchPartnerAccessToken(env: Env): Promise<string> {
  const tokenResponse = await fetch(`${env.TESLA_AUTH_BASE_URL}/oauth2/v3/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: env.TESLA_CLIENT_ID,
      client_secret: env.TESLA_CLIENT_SECRET,
      scope: "vehicle_device_data vehicle_cmds vehicle_charging_cmds",
      audience: env.TESLA_FLEET_API_BASE_URL,
    }),
  });

  if (!tokenResponse.ok) {
    throw new Error(`Tesla token endpoint returned HTTP ${tokenResponse.status}`);
  }

  const data = (await tokenResponse.json()) as TeslaTokenResponse;
  if (!data.access_token) {
    throw new Error("Tesla token response did not include an access_token.");
  }
  return data.access_token;
}

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// MARK: - POST /api/telemetry
//
// Receives Tesla Fleet Telemetry webhook events. Tesla's telemetry stream only pushes
// fields that changed (not a full vehicle snapshot each time), shaped as a `data` array
// of `{key, value}` pairs — e.g. `{key: "ChargeState_ChargePortLatch", value: {stringValue: "Disengaged"}}`.

export interface TelemetryDatumValue {
  stringValue?: string;
  booleanValue?: boolean;
  doubleValue?: number;
  intValue?: number;
}

export interface TelemetryDatum {
  key?: string;
  value?: TelemetryDatumValue;
}

export interface TelemetryPayload {
  vin: string;
  data: TelemetryDatum[];
  createdAt?: string;
}

export class TelemetryParseError extends Error {}

const CHARGE_PORT_LATCH_KEY = "ChargeState_ChargePortLatch";
const CHARGING_STATE_KEY = "ChargeState_ChargingState";
const DISENGAGED_LATCH_VALUE = "Disengaged";
const ACTIVE_CHARGING_VALUE = "Charging";

/// Strict parsing with safe guards: throws `TelemetryParseError` (-> HTTP 400) for a
/// structurally invalid payload, but silently drops individual malformed `data` entries
/// rather than failing the whole webhook over one bad field.
export function parseTelemetryPayload(raw: unknown): TelemetryPayload {
  if (typeof raw !== "object" || raw === null) {
    throw new TelemetryParseError("Telemetry payload must be a JSON object.");
  }
  const record = raw as Record<string, unknown>;

  if (typeof record.vin !== "string" || record.vin.length === 0) {
    throw new TelemetryParseError("Missing required field: vin.");
  }

  let data: TelemetryDatum[] = [];
  if (record.data !== undefined) {
    if (!Array.isArray(record.data)) {
      throw new TelemetryParseError("Field 'data' must be an array.");
    }
    data = record.data.filter(
      (entry): entry is TelemetryDatum =>
        typeof entry === "object" && entry !== null && typeof (entry as TelemetryDatum).key === "string"
    );
  }

  return {
    vin: record.vin,
    data,
    createdAt: typeof record.createdAt === "string" ? record.createdAt : undefined,
  };
}

function findStringValue(payload: TelemetryPayload, key: string): string | undefined {
  return payload.data.find((datum) => datum.key === key)?.value?.stringValue;
}

/// A charge-port unplug is only classified "critical" (worth a DND-bypassing alert) when
/// this SAME telemetry message also confirms the vehicle was actively charging. Tesla only
/// sends changed fields, so if ChargingState isn't present we can't confirm that context —
/// we deliberately don't alert on an unconfirmed guess, to avoid critical-alert fatigue.
export function detectCriticalUnplugEvent(payload: TelemetryPayload): boolean {
  if (findStringValue(payload, CHARGE_PORT_LATCH_KEY) !== DISENGAGED_LATCH_VALUE) {
    return false;
  }
  return findStringValue(payload, CHARGING_STATE_KEY) === ACTIVE_CHARGING_VALUE;
}

async function handleTelemetry(request: Request, env: Env): Promise<Response> {
  let raw: unknown;
  try {
    raw = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body." }, 400);
  }

  let payload: TelemetryPayload;
  try {
    payload = parseTelemetryPayload(raw);
  } catch (error) {
    if (error instanceof TelemetryParseError) {
      return jsonResponse({ error: error.message }, 400);
    }
    throw error;
  }

  const isCriticalUnplug = detectCriticalUnplugEvent(payload);
  if (!isCriticalUnplug) {
    return jsonResponse({ status: "received", vin: payload.vin, alertDispatched: false });
  }

  try {
    await sendCriticalUnplugAlert(env, payload.vin);
    return jsonResponse({ status: "received", vin: payload.vin, alertDispatched: true });
  } catch (error) {
    // The telemetry event itself was valid — acknowledge it regardless of whether the
    // downstream push succeeded, so Tesla's webhook sender doesn't retry a good event.
    return jsonResponse({
      status: "received",
      vin: payload.vin,
      alertDispatched: false,
      alertError: describeError(error),
    });
  }
}

// MARK: - APNs critical alert dispatch
//
// Token-based (JWT) auth per Apple's APNs Provider API: a JWT signed with the .p8
// auth key using ES256, sent as a bearer token on each request. Workers' `fetch()`
// negotiates HTTP/2 with api.push.apple.com automatically — no manual client config
// needed beyond the request itself.

const APNS_HOST = "https://api.push.apple.com";

function base64UrlEncode(input: string | ArrayBuffer | Uint8Array): string {
  let binary: string;
  if (typeof input === "string") {
    binary = input;
  } else {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const base64 = pem.replace(/-----BEGIN [^-]+-----|-----END [^-]+-----|\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

type ApnsCredentials = Pick<Env, "APNS_KEY_P8" | "APNS_KEY_ID" | "APNS_TEAM_ID">;

/// Builds a fresh ES256 provider token for this request. Apple allows reusing a token
/// for up to ~1 hour; a higher-volume deployment should cache this (e.g. in Workers KV)
/// instead of signing one per telemetry event.
export async function buildApnsProviderToken(env: ApnsCredentials): Promise<string> {
  const header = { alg: "ES256", kid: env.APNS_KEY_ID };
  const claims = { iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) };

  const encodedHeader = base64UrlEncode(JSON.stringify(header));
  const encodedClaims = base64UrlEncode(JSON.stringify(claims));
  const signingInput = `${encodedHeader}.${encodedClaims}`;

  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(env.APNS_KEY_P8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(signingInput)
  );

  return `${signingInput}.${base64UrlEncode(signature)}`;
}

interface CriticalAlertPayload {
  aps: {
    alert: { title: string; body: string };
    sound: { critical: 1; name: string; volume: number };
    "interruption-level": "critical";
  };
  vin: string;
  event: string;
}

export function buildCriticalUnplugAlertPayload(vin: string): CriticalAlertPayload {
  return {
    aps: {
      alert: {
        title: "Vehicle Unplugged While Charging",
        body: `Your Tesla (VIN ${vin}) was unplugged mid-charge. If this wasn't you, check on it now.`,
      },
      sound: { critical: 1, name: "default", volume: 1.0 },
      "interruption-level": "critical",
    },
    vin,
    event: "charge_port_disengaged_while_charging",
  };
}

async function sendCriticalUnplugAlert(env: Env, vin: string): Promise<void> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_BUNDLE_ID || !env.APNS_DEVICE_TOKEN) {
    throw new Error("APNs is not fully configured on this worker.");
  }

  const token = await buildApnsProviderToken(env);
  const payload = buildCriticalUnplugAlertPayload(vin);

  const response = await fetch(`${APNS_HOST}/3/device/${env.APNS_DEVICE_TOKEN}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": env.APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const details = await response.text().catch(() => "");
    throw new Error(`APNs rejected the push: HTTP ${response.status} ${details}`);
  }
}
