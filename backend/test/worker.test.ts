import { afterEach, describe, expect, it, vi } from "vitest";
import worker, {
  buildApnsProviderToken,
  buildCriticalUnplugAlertPayload,
  detectCriticalUnplugEvent,
  parseTelemetryPayload,
  TelemetryParseError,
  type Env,
  type TelemetryPayload,
} from "../src/index";

function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    TESLA_FLEET_API_BASE_URL: "https://fleet-api.prd.na.vn.cloud.tesla.com",
    TESLA_AUTH_BASE_URL: "https://auth.tesla.com",
    TESLA_CLIENT_ID: "",
    TESLA_CLIENT_SECRET: "",
    TESLA_PUBLIC_KEY_PEM: "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...\n-----END PUBLIC KEY-----\n",
    APNS_KEY_P8: "",
    APNS_KEY_ID: "TESTKEYID1",
    APNS_TEAM_ID: "TESTTEAMID",
    APNS_BUNDLE_ID: "com.sentryguard.app",
    APNS_DEVICE_TOKEN: "device-token-abc123",
    ...overrides,
  };
}

const ctx = {
  waitUntil: () => {},
  passThroughOnException: () => {},
} as unknown as ExecutionContext;

function requestUrlOf(input: RequestInfo | URL): string {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.toString();
  return input.url;
}

function base64UrlDecode(segment: string): Uint8Array {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(segment.length + ((4 - (segment.length % 4)) % 4), "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlDecodeToJSON(segment: string): unknown {
  return JSON.parse(new TextDecoder().decode(base64UrlDecode(segment)));
}

/** A real P-256 key pair + PKCS8 PEM export, generated fresh per test via Web Crypto —
 * no fixture files, no external tooling, and it lets us cryptographically verify the
 * JWT signature `buildApnsProviderToken` produces, not just its shape. */
async function generateTestApnsKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const pkcs8 = (await crypto.subtle.exportKey("pkcs8", keyPair.privateKey)) as ArrayBuffer;
  const base64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  const lines = base64.match(/.{1,64}/g) ?? [];
  const pem = `-----BEGIN PRIVATE KEY-----\n${lines.join("\n")}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: keyPair.publicKey };
}

function telemetryDatum(key: string, stringValue: string) {
  return { key, value: { stringValue } };
}

afterEach(() => {
  vi.restoreAllMocks();
});

// MARK: - Route matching

describe("route matching", () => {
  it("returns 404 for an unknown path", async () => {
    const response = await worker.fetch(new Request("https://worker.example/does-not-exist"), makeEnv(), ctx);
    expect(response.status).toBe(404);
  });

  it("returns 404 for a known path with the wrong method", async () => {
    const response = await worker.fetch(
      new Request("https://worker.example/health", { method: "POST" }),
      makeEnv(),
      ctx
    );
    expect(response.status).toBe(404);
  });
});

// MARK: - GET /health

describe("GET /health", () => {
  it("returns 200 with status and a version string", async () => {
    const response = await worker.fetch(new Request("https://worker.example/health"), makeEnv(), ctx);

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("application/json");
    const body = (await response.json()) as { status: string; version: string };
    expect(body.status).toBe("ok");
    expect(typeof body.version).toBe("string");
    expect(body.version.length).toBeGreaterThan(0);
  });
});

// MARK: - GET /.well-known/appspecific/com.tesla.3p.public-key.pem

describe("GET /.well-known/appspecific/com.tesla.3p.public-key.pem", () => {
  const path = "https://worker.example/.well-known/appspecific/com.tesla.3p.public-key.pem";

  it("serves the configured PEM with the correct content type", async () => {
    const response = await worker.fetch(new Request(path), makeEnv(), ctx);

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("application/x-pem-file");
    const text = await response.text();
    expect(text).toContain("BEGIN PUBLIC KEY");
  });

  it("returns 500 when no key is configured on the worker", async () => {
    const env = makeEnv({ TESLA_PUBLIC_KEY_PEM: "" });
    const response = await worker.fetch(new Request(path), env, ctx);

    expect(response.status).toBe(500);
  });
});

// MARK: - POST /api/partner-keys

describe("POST /api/partner-keys", () => {
  const path = "https://worker.example/api/partner-keys";

  it("returns 503 when Tesla partner credentials are not configured", async () => {
    const env = makeEnv({ TESLA_CLIENT_ID: "", TESLA_CLIENT_SECRET: "" });
    const response = await worker.fetch(new Request(path, { method: "POST" }), env, ctx);

    expect(response.status).toBe(503);
  });

  it("registers the partner domain when Tesla responds successfully", async () => {
    const env = makeEnv({ TESLA_CLIENT_ID: "test-client", TESLA_CLIENT_SECRET: "test-secret" });
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = requestUrlOf(input as RequestInfo | URL);
      if (url.includes("/oauth2/v3/token")) {
        return new Response(JSON.stringify({ access_token: "mock-token" }), { status: 200 });
      }
      if (url.includes("/api/1/partner_accounts")) {
        return new Response(JSON.stringify({ response: { domain: "worker.example" } }), {
          status: 200,
        });
      }
      throw new Error(`Unexpected fetch to ${url}`);
    });

    const response = await worker.fetch(new Request(path, { method: "POST" }), env, ctx);

    expect(response.status).toBe(200);
    const body = (await response.json()) as { status: string; domain: string };
    expect(body.status).toBe("registered");
    // Must be the worker's own request host, not TESLA_FLEET_API_BASE_URL's host — Tesla
    // verifies domain ownership by fetching the public key from whatever domain is
    // registered here, and it can only ever reach the worker's own domain.
    expect(body.domain).toBe("worker.example");
  });

  it("returns 502 when the Tesla token request fails", async () => {
    const env = makeEnv({ TESLA_CLIENT_ID: "test-client", TESLA_CLIENT_SECRET: "test-secret" });
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response("unauthorized", { status: 401 }));

    const response = await worker.fetch(new Request(path, { method: "POST" }), env, ctx);

    expect(response.status).toBe(502);
  });

  it("returns 502 when Tesla rejects the partner registration", async () => {
    const env = makeEnv({ TESLA_CLIENT_ID: "test-client", TESLA_CLIENT_SECRET: "test-secret" });
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = requestUrlOf(input as RequestInfo | URL);
      if (url.includes("/oauth2/v3/token")) {
        return new Response(JSON.stringify({ access_token: "mock-token" }), { status: 200 });
      }
      return new Response(JSON.stringify({ error: "invalid_domain" }), { status: 400 });
    });

    const response = await worker.fetch(new Request(path, { method: "POST" }), env, ctx);

    expect(response.status).toBe(502);
  });
});

// MARK: - parseTelemetryPayload / detectCriticalUnplugEvent (pure logic)

describe("parseTelemetryPayload", () => {
  it("parses a minimal valid payload with no data array", () => {
    const payload = parseTelemetryPayload({ vin: "5YJ3E1EA0PF000000" });
    expect(payload.vin).toBe("5YJ3E1EA0PF000000");
    expect(payload.data).toEqual([]);
  });

  it("parses a payload with a well-formed data array", () => {
    const payload = parseTelemetryPayload({
      vin: "5YJ3E1EA0PF000000",
      data: [telemetryDatum("ChargeState_ChargePortLatch", "Disengaged")],
    });
    expect(payload.data).toHaveLength(1);
    expect(payload.data[0]?.key).toBe("ChargeState_ChargePortLatch");
  });

  it("throws for a non-object payload", () => {
    expect(() => parseTelemetryPayload("not an object")).toThrow(TelemetryParseError);
    expect(() => parseTelemetryPayload(null)).toThrow(TelemetryParseError);
  });

  it("throws when vin is missing", () => {
    expect(() => parseTelemetryPayload({})).toThrow(TelemetryParseError);
  });

  it("throws when vin is an empty string", () => {
    expect(() => parseTelemetryPayload({ vin: "" })).toThrow(TelemetryParseError);
  });

  it("throws when data is present but not an array", () => {
    expect(() => parseTelemetryPayload({ vin: "5YJ3E1EA0PF000000", data: { foo: "bar" } })).toThrow(
      TelemetryParseError
    );
  });

  it("safely drops malformed entries within the data array instead of throwing", () => {
    const payload = parseTelemetryPayload({
      vin: "5YJ3E1EA0PF000000",
      data: [
        telemetryDatum("ChargeState_ChargePortLatch", "Disengaged"),
        "not an object",
        42,
        null,
        { noKeyField: true },
      ],
    });
    expect(payload.data).toHaveLength(1);
    expect(payload.data[0]?.key).toBe("ChargeState_ChargePortLatch");
  });

  it("safely handles an entry whose value is missing or malformed", () => {
    const payload = parseTelemetryPayload({
      vin: "5YJ3E1EA0PF000000",
      data: [{ key: "ChargeState_ChargePortLatch" }, { key: "SomeKey", value: "not-an-object" }],
    });
    expect(detectCriticalUnplugEvent(payload)).toBe(false);
  });
});

describe("detectCriticalUnplugEvent", () => {
  function payloadWith(entries: Array<[string, string]>): TelemetryPayload {
    return parseTelemetryPayload({
      vin: "5YJ3E1EA0PF000000",
      data: entries.map(([key, value]) => telemetryDatum(key, value)),
    });
  }

  it("is false when ChargePortLatch is not present at all", () => {
    expect(detectCriticalUnplugEvent(payloadWith([["ChargeState_ChargingState", "Charging"]]))).toBe(false);
  });

  it("is false when ChargePortLatch is Engaged", () => {
    expect(
      detectCriticalUnplugEvent(
        payloadWith([
          ["ChargeState_ChargePortLatch", "Engaged"],
          ["ChargeState_ChargingState", "Charging"],
        ])
      )
    ).toBe(false);
  });

  it("is false when ChargePortLatch is Disengaged but ChargingState is absent (unconfirmed context)", () => {
    expect(detectCriticalUnplugEvent(payloadWith([["ChargeState_ChargePortLatch", "Disengaged"]]))).toBe(false);
  });

  it("is false when ChargePortLatch is Disengaged and ChargingState is explicitly not Charging", () => {
    expect(
      detectCriticalUnplugEvent(
        payloadWith([
          ["ChargeState_ChargePortLatch", "Disengaged"],
          ["ChargeState_ChargingState", "Disconnected"],
        ])
      )
    ).toBe(false);
  });

  it("is true when ChargePortLatch is Disengaged and ChargingState is Charging in the same message", () => {
    expect(
      detectCriticalUnplugEvent(
        payloadWith([
          ["ChargeState_ChargePortLatch", "Disengaged"],
          ["ChargeState_ChargingState", "Charging"],
        ])
      )
    ).toBe(true);
  });
});

describe("buildCriticalUnplugAlertPayload", () => {
  it("builds a critical, DND-bypassing APNs payload for the given VIN", () => {
    const payload = buildCriticalUnplugAlertPayload("5YJ3E1EA0PF000000");

    expect(payload.aps.sound).toEqual({ critical: 1, name: "default", volume: 1.0 });
    expect(payload.aps["interruption-level"]).toBe("critical");
    expect(payload.aps.alert.body).toContain("5YJ3E1EA0PF000000");
    expect(payload.vin).toBe("5YJ3E1EA0PF000000");
    expect(payload.event).toBe("charge_port_disengaged_while_charging");
  });
});

// MARK: - buildApnsProviderToken (real ES256 JWT, cryptographically verified)

describe("buildApnsProviderToken", () => {
  it("produces a well-formed, cryptographically valid ES256 JWT", async () => {
    const { pem, publicKey } = await generateTestApnsKey();

    const token = await buildApnsProviderToken({
      APNS_KEY_P8: pem,
      APNS_KEY_ID: "ABC1234DEF",
      APNS_TEAM_ID: "TEAM99999X",
    });

    const segments = token.split(".");
    expect(segments).toHaveLength(3);
    const [headerSegment, claimsSegment, signatureSegment] = segments as [string, string, string];

    expect(base64UrlDecodeToJSON(headerSegment)).toEqual({ alg: "ES256", kid: "ABC1234DEF" });

    const claims = base64UrlDecodeToJSON(claimsSegment) as { iss: string; iat: number };
    expect(claims.iss).toBe("TEAM99999X");
    expect(claims.iat).toBeGreaterThan(Math.floor(Date.now() / 1000) - 5);
    expect(claims.iat).toBeLessThanOrEqual(Math.floor(Date.now() / 1000));

    const signingInput = `${headerSegment}.${claimsSegment}`;
    const isValid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      base64UrlDecode(signatureSegment),
      new TextEncoder().encode(signingInput)
    );
    expect(isValid).toBe(true);
  });

  it("produces a different signature for a different signing key (sanity check against a fixed/fake signature)", async () => {
    const keyA = await generateTestApnsKey();
    const keyB = await generateTestApnsKey();

    const tokenA = await buildApnsProviderToken({ APNS_KEY_P8: keyA.pem, APNS_KEY_ID: "K1", APNS_TEAM_ID: "T1" });
    const tokenB = await buildApnsProviderToken({ APNS_KEY_P8: keyB.pem, APNS_KEY_ID: "K1", APNS_TEAM_ID: "T1" });

    expect(tokenA.split(".")[2]).not.toBe(tokenB.split(".")[2]);
  });
});

// MARK: - POST /api/telemetry (full HTTP flow, including APNs dispatch)

describe("POST /api/telemetry", () => {
  const path = "https://worker.example/api/telemetry";

  function telemetryRequest(body: unknown, raw = false): Request {
    return new Request(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: raw ? (body as string) : JSON.stringify(body),
    });
  }

  it("acknowledges a non-critical payload without dispatching an alert", async () => {
    const response = await worker.fetch(
      telemetryRequest({
        vin: "5YJ3E1EA0PF000000",
        data: [telemetryDatum("ChargeState_ChargePortLatch", "Engaged")],
      }),
      makeEnv(),
      ctx
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { status: string; vin: string; alertDispatched: boolean };
    expect(body.status).toBe("received");
    expect(body.vin).toBe("5YJ3E1EA0PF000000");
    expect(body.alertDispatched).toBe(false);
  });

  it("returns 400 when the vin field is missing", async () => {
    const response = await worker.fetch(telemetryRequest({ data: [] }), makeEnv(), ctx);
    expect(response.status).toBe(400);
  });

  it("returns 400 when data is present but not an array", async () => {
    const response = await worker.fetch(
      telemetryRequest({ vin: "5YJ3E1EA0PF000000", data: { not: "an array" } }),
      makeEnv(),
      ctx
    );
    expect(response.status).toBe(400);
  });

  it("returns 400 for a malformed JSON body", async () => {
    const response = await worker.fetch(telemetryRequest("not json", true), makeEnv(), ctx);
    expect(response.status).toBe(400);
  });

  it("dispatches a critical APNs alert and reports alertDispatched: true on success", async () => {
    const { pem } = await generateTestApnsKey();
    const env = makeEnv({ APNS_KEY_P8: pem });

    let capturedRequest: Request | undefined;
    let capturedBody: unknown;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      capturedRequest = new Request(input as RequestInfo, init);
      capturedBody = JSON.parse((init?.body as string) ?? "{}");
      return new Response(null, { status: 200 });
    });

    const response = await worker.fetch(
      telemetryRequest({
        vin: "5YJ3E1EA0PF000000",
        data: [
          telemetryDatum("ChargeState_ChargePortLatch", "Disengaged"),
          telemetryDatum("ChargeState_ChargingState", "Charging"),
        ],
      }),
      env,
      ctx
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { status: string; alertDispatched: boolean };
    expect(body.alertDispatched).toBe(true);

    expect(capturedRequest?.url).toBe("https://api.push.apple.com/3/device/device-token-abc123");
    expect(capturedRequest?.headers.get("apns-topic")).toBe("com.sentryguard.app");
    expect(capturedRequest?.headers.get("apns-push-type")).toBe("alert");
    expect(capturedRequest?.headers.get("apns-priority")).toBe("10");
    expect(capturedRequest?.headers.get("authorization")).toMatch(/^bearer .+\..+\..+$/);
    expect((capturedBody as { vin: string }).vin).toBe("5YJ3E1EA0PF000000");
  });

  it("still acknowledges the webhook (200) when APNs is not configured", async () => {
    const env = makeEnv({ APNS_KEY_P8: "" });

    const response = await worker.fetch(
      telemetryRequest({
        vin: "5YJ3E1EA0PF000000",
        data: [
          telemetryDatum("ChargeState_ChargePortLatch", "Disengaged"),
          telemetryDatum("ChargeState_ChargingState", "Charging"),
        ],
      }),
      env,
      ctx
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { status: string; alertDispatched: boolean; alertError?: string };
    expect(body.status).toBe("received");
    expect(body.alertDispatched).toBe(false);
    expect(body.alertError).toBeDefined();
  });

  it("still acknowledges the webhook (200) when APNs rejects the push", async () => {
    const { pem } = await generateTestApnsKey();
    const env = makeEnv({ APNS_KEY_P8: pem });
    vi.spyOn(globalThis, "fetch").mockImplementation(async () =>
      new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 })
    );

    const response = await worker.fetch(
      telemetryRequest({
        vin: "5YJ3E1EA0PF000000",
        data: [
          telemetryDatum("ChargeState_ChargePortLatch", "Disengaged"),
          telemetryDatum("ChargeState_ChargingState", "Charging"),
        ],
      }),
      env,
      ctx
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { alertDispatched: boolean; alertError?: string };
    expect(body.alertDispatched).toBe(false);
    expect(body.alertError).toContain("BadDeviceToken");
  });
});
