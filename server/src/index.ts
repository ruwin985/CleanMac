interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  PADDLE_WEBHOOK_SECRET: string;
  PADDLE_API_KEY?: string;
  PADDLE_API_BASE_URL?: string;
  RESEND_API_KEY?: string;
  RESEND_FROM?: string;
  RESEND_REPLY_TO?: string;
  EMAIL_DELIVERY_MODE?: string;
  LICENSE_SIGNING_KEY: string;
  LICENSE_ENCRYPTION_KEY?: string;
  LICENSE_HASH_PEPPER?: string;
  SERVER_TOKEN_SECRET: string;
  ALLOWED_PRICE_IDS?: string;
  ALLOWED_PRODUCT_IDS?: string;
  LICENSE_MAX_DEVICES?: string;
  APP_NAME?: string;
  SUPPORT_EMAIL?: string;
  PADDLE_SIGNATURE_TOLERANCE_SECONDS?: string;
}

type JsonValue = string | number | boolean | null | JsonObject | JsonValue[];
type JsonObject = { [key: string]: JsonValue | undefined };

interface PaddleEvent {
  event_id?: string;
  notification_id?: string;
  event_type?: string;
  occurred_at?: string;
  data?: JsonObject;
}

interface LicenseRow {
  license_id: string;
  license_code_hash: string;
  license_code_ciphertext: string | null;
  license_code_iv: string | null;
  license_code_prefix: string;
  paddle_transaction_id: string;
  customer_email: string | null;
  status: string;
  issued_at: string;
  last_emailed_at: string | null;
  email_send_id: string | null;
  metadata?: JsonObject;
}

interface OrderRow {
  paddle_transaction_id: string;
  paddle_customer_id: string | null;
  customer_email: string | null;
  price_id: string | null;
  product_id: string | null;
  currency_code: string | null;
  total_amount_minor: number | null;
  status: string;
  raw_event_id: string | null;
}

interface WebhookEventRow {
  event_id: string;
  event_type: string;
  processed_at: string | null;
}

interface ActivationRequest {
  licenseCode?: string;
  deviceId?: string;
  appVersion?: string;
  buildNumber?: string;
  platform?: string;
}

const licenseAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const licenseVersion = 3;
const licenseContext = "CleanMac.short-license.v3";
const secondsPerDay = 86400;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "OPTIONS") return corsResponse(null, 204);
      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse({ ok: true, service: "cleanmac-license" });
      }
      if (request.method === "POST" && url.pathname === "/webhooks/paddle") {
        return handlePaddleWebhook(request, env);
      }
      if (request.method === "POST" && url.pathname === "/licenses/activate") {
        return handleLicenseActivation(request, env);
      }
      return jsonResponse({ ok: false, message: "Not found" }, 404);
    } catch (error) {
      return jsonResponse({ ok: false, message: errorMessage(error) }, 500);
    }
  }
};

async function handlePaddleWebhook(request: Request, env: Env): Promise<Response> {
  const rawBody = await request.text();
  await verifyPaddleSignature(rawBody, request.headers.get("Paddle-Signature"), env);

  const event = JSON.parse(rawBody) as PaddleEvent;
  const eventID = event.event_id ?? event.notification_id;
  const eventType = event.event_type;
  if (!eventID || !eventType) return jsonResponse({ ok: false, message: "Invalid Paddle event" }, 400);

  const existingEvent = await first<WebhookEventRow>(env, `cleanmac_webhook_events?event_id=eq.${encodeURIComponent(eventID)}&select=event_id,event_type,processed_at`);
  if (existingEvent?.processed_at) return jsonResponse({ ok: true, duplicate: true });

  if (!existingEvent) {
    await insertRow(env, "cleanmac_webhook_events", {
      event_id: eventID,
      event_type: eventType,
      paddle_transaction_id: stringValue(event.data?.id),
      payload: event as unknown as JsonObject
    });
  }

  if (eventType !== "transaction.completed") {
    await markWebhookProcessed(env, eventID);
    return jsonResponse({ ok: true, ignored: eventType });
  }

  try {
    const order = await orderFromPaddleEvent(event, env, eventID);
    assertAllowedOrder(order, env);
    await upsertRow(env, "cleanmac_orders", "paddle_transaction_id", { ...order });

    let license = await first<LicenseRow>(env, `cleanmac_licenses?paddle_transaction_id=eq.${encodeURIComponent(order.paddle_transaction_id)}&select=*`);
    let plainLicenseCode: string | null = null;

    if (!license) {
      plainLicenseCode = await generateLicenseCode(env);
      const encryptedLicenseCode = await encryptLicenseCode(plainLicenseCode, env);
      license = await insertRow<LicenseRow>(env, "cleanmac_licenses", {
        license_code_hash: await licenseCodeHash(plainLicenseCode, env),
        license_code_ciphertext: encryptedLicenseCode.ciphertext,
        license_code_iv: encryptedLicenseCode.iv,
        license_code_prefix: plainLicenseCode.slice(0, 10),
        paddle_transaction_id: order.paddle_transaction_id,
        customer_email: order.customer_email,
        metadata: {
          source: "paddle_webhook",
          event_id: eventID,
          price_id: order.price_id,
          product_id: order.product_id
        }
      });
    } else if (!license.last_emailed_at) {
      plainLicenseCode = await decryptLicenseCode(license, env);
    }

    if (!plainLicenseCode && license.last_emailed_at) {
      await markWebhookProcessed(env, eventID);
      return jsonResponse({ ok: true, licenseId: license.license_id, alreadyIssued: true });
    }

    if (!plainLicenseCode) throw new Error("Existing license code cannot be recovered for email retry");

    const emailResult = await sendLicenseEmail(env, order, plainLicenseCode);
    await patchRows(env, "cleanmac_licenses", `license_id=eq.${license.license_id}`, {
      last_emailed_at: new Date().toISOString(),
      email_send_id: emailResult.id
    });
    await markWebhookProcessed(env, eventID);

    return jsonResponse({ ok: true, licenseId: license.license_id, email: maskEmail(order.customer_email) });
  } catch (error) {
    await patchRows(env, "cleanmac_webhook_events", `event_id=eq.${encodeURIComponent(eventID)}`, {
      error_message: errorMessage(error)
    });
    return jsonResponse({ ok: false, message: errorMessage(error) }, 500);
  }
}

async function handleLicenseActivation(request: Request, env: Env): Promise<Response> {
  const body = await request.json<ActivationRequest>();
  const licenseCode = normalizeLicenseCode(body.licenseCode ?? "");
  const deviceId = (body.deviceId ?? "").trim();

  if (!licenseCode) return jsonResponse({ valid: false, message: "授权码不能为空" }, 400);
  if (!deviceId) return jsonResponse({ valid: false, message: "设备标识不能为空" }, 400);

  const codeHash = await licenseCodeHash(licenseCode, env);
  const license = await first<LicenseRow>(env, `cleanmac_licenses?license_code_hash=eq.${encodeURIComponent(codeHash)}&select=*`);
  if (!license) return jsonResponse({ valid: false, message: "授权码不存在或尚未同步" }, 404);
  if (license.status !== "active") return jsonResponse({ valid: false, message: "授权码已停用，请联系支持" }, 403);

  const order = await first<OrderRow>(env, `cleanmac_orders?paddle_transaction_id=eq.${encodeURIComponent(license.paddle_transaction_id)}&select=*`);
  if (!order || order.status !== "completed") return jsonResponse({ valid: false, message: "订单状态无效，请联系支持" }, 403);

  const deviceHash = await sha256Hex(deviceId);
  const activations = await selectRows<{ device_id_hash: string }>(env, `cleanmac_activations?license_id=eq.${license.license_id}&select=device_id_hash`);
  const existingActivation = activations.find((activation) => activation.device_id_hash === deviceHash);
  const maxDevices = positiveInteger(env.LICENSE_MAX_DEVICES, 3);
  if (!existingActivation && activations.length >= maxDevices) {
    return jsonResponse({ valid: false, message: `该授权码已达到 ${maxDevices} 台设备激活上限` }, 403);
  }

  const activationPayload = {
    license_id: license.license_id,
    device_id_hash: deviceHash,
    app_version: body.appVersion ?? null,
    build_number: body.buildNumber ?? null,
    platform: body.platform ?? null,
    last_seen_at: new Date().toISOString()
  };
  if (existingActivation) {
    await patchRows(env, "cleanmac_activations", `license_id=eq.${license.license_id}&device_id_hash=eq.${deviceHash}`, activationPayload);
  } else {
    await insertRow(env, "cleanmac_activations", activationPayload);
  }

  const token = await signedActivationToken(env, {
    licenseId: license.license_id,
    transactionId: license.paddle_transaction_id,
    deviceIdHash: deviceHash,
    issuedAt: Math.floor(Date.now() / 1000),
    expiresAt: Math.floor(Date.now() / 1000) + 90 * 24 * 60 * 60
  });

  return jsonResponse({
    valid: true,
    token,
    license: {
      licenseId: license.license_id,
      product: env.APP_NAME ?? "CleanMac",
      transactionId: license.paddle_transaction_id,
      email: license.customer_email,
      issuedAt: license.issued_at
    }
  });
}

async function orderFromPaddleEvent(event: PaddleEvent, env: Env, eventID: string): Promise<OrderRow> {
  const data = event.data ?? {};
  const transactionID = requiredString(data.id, "Missing transaction id");
  const customerID = stringValue(data.customer_id);
  let customerEmail = findEmail(data);
  if (!customerEmail && customerID && env.PADDLE_API_KEY) {
    customerEmail = await fetchPaddleCustomerEmail(env, customerID);
  }

  const lineItem = firstLineItem(data);
  const priceID = findPriceID(lineItem) ?? stringValue(data.price_id);
  const productID = findProductID(lineItem) ?? stringValue(data.product_id);
  const totals = objectValue(objectValue(data.details)?.totals) ?? objectValue(data.totals);

  return {
    paddle_transaction_id: transactionID,
    paddle_customer_id: customerID,
    customer_email: customerEmail,
    price_id: priceID,
    product_id: productID,
    currency_code: stringValue(data.currency_code),
    total_amount_minor: numberValue(totals?.total),
    status: stringValue(data.status) ?? "completed",
    raw_event_id: eventID
  };
}

function assertAllowedOrder(order: OrderRow, env: Env): void {
  if (order.status !== "completed") throw new Error(`Transaction is not completed: ${order.status}`);
  const allowedPriceIDs = csvSet(env.ALLOWED_PRICE_IDS);
  if (allowedPriceIDs.size > 0 && (!order.price_id || !allowedPriceIDs.has(order.price_id))) {
    throw new Error(`Unexpected Paddle price id: ${order.price_id ?? "missing"}`);
  }
  const allowedProductIDs = csvSet(env.ALLOWED_PRODUCT_IDS);
  if (allowedProductIDs.size > 0 && (!order.product_id || !allowedProductIDs.has(order.product_id))) {
    throw new Error(`Unexpected Paddle product id: ${order.product_id ?? "missing"}`);
  }
}

async function verifyPaddleSignature(rawBody: string, signatureHeader: string | null, env: Env): Promise<void> {
  if (!signatureHeader) throw new Error("Missing Paddle-Signature header");
  if (!env.PADDLE_WEBHOOK_SECRET) throw new Error("Missing PADDLE_WEBHOOK_SECRET");

  const parsed = parsePaddleSignatureHeader(signatureHeader);
  const timestamp = parsed.ts?.[0];
  const signatures = parsed.h1 ?? [];
  if (!timestamp || signatures.length === 0) throw new Error("Invalid Paddle-Signature header");

  const tolerance = positiveInteger(env.PADDLE_SIGNATURE_TOLERANCE_SECONDS, 300);
  const ageSeconds = Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp));
  if (!Number.isFinite(ageSeconds) || ageSeconds > tolerance) throw new Error("Expired Paddle webhook signature");

  const signedPayload = `${timestamp}:${rawBody}`;
  const expected = await hmacSha256Hex(env.PADDLE_WEBHOOK_SECRET, signedPayload);
  if (!signatures.some((signature) => constantTimeEqualHex(signature, expected))) {
    throw new Error("Invalid Paddle webhook signature");
  }
}

function parsePaddleSignatureHeader(header: string): Record<string, string[]> {
  const result: Record<string, string[]> = {};
  for (const part of header.split(";")) {
    const [key, value] = part.split("=");
    if (!key || !value) continue;
    const normalizedKey = key.trim();
    result[normalizedKey] = [...(result[normalizedKey] ?? []), value.trim()];
  }
  return result;
}

async function generateLicenseCode(env: Env): Promise<string> {
  const signedPayload = new Uint8Array(8);
  signedPayload[0] = licenseVersion;
  const issuedAtDay = Math.floor(Date.now() / 1000 / secondsPerDay);
  signedPayload[1] = (issuedAtDay >> 8) & 0xff;
  signedPayload[2] = issuedAtDay & 0xff;
  crypto.getRandomValues(signedPayload.subarray(3, 8));

  const signingKey = base64ToBytes(env.LICENSE_SIGNING_KEY);
  if (signingKey.length < 16) throw new Error("LICENSE_SIGNING_KEY must be at least 16 bytes");
  const tag = new Uint8Array(await hmacSha256(signingKey, concatBytes(utf8Bytes(licenseContext), signedPayload))).slice(0, 5);
  return groupedLicenseCode(concatBytes(signedPayload, tag));
}

function groupedLicenseCode(payload: Uint8Array): string {
  const encoded = base32Encode(payload);
  const groups = encoded.match(/.{1,7}/g) ?? [encoded];
  return `CM-${groups.join("-")}`;
}

function base32Encode(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let output = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      output += licenseAlphabet[(value >> bits) & 31];
      value &= (1 << bits) - 1;
    }
  }
  if (bits > 0) output += licenseAlphabet[(value << (5 - bits)) & 31];
  return output;
}

async function sendLicenseEmail(env: Env, order: OrderRow, licenseCode: string): Promise<{ id: string }> {
  const email = order.customer_email;
  if (!email) throw new Error("Paddle order has no customer email");

  const appName = env.APP_NAME ?? "CleanMac";
  const supportLine = env.SUPPORT_EMAIL ? `如需帮助，请联系 ${env.SUPPORT_EMAIL}。` : "如需帮助，请回复此邮件。";
  const text = [
    `感谢购买 ${appName}。`,
    "",
    `你的授权码：${licenseCode}`,
    "",
    "请打开 CleanMac，在授权窗口粘贴此授权码完成激活。",
    supportLine
  ].join("\n");
  const html = `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.6;color:#1d1d1f">
      <h2>感谢购买 ${escapeHTML(appName)}</h2>
      <p>你的授权码：</p>
      <p style="font-size:20px;font-weight:700;letter-spacing:1px;background:#f5f5f7;padding:14px 16px;border-radius:12px;display:inline-block">${escapeHTML(licenseCode)}</p>
      <p>请打开 CleanMac，在授权窗口粘贴此授权码完成激活。</p>
      <p style="color:#6e6e73">${escapeHTML(supportLine)}</p>
    </div>`;

  if ((env.EMAIL_DELIVERY_MODE ?? "resend") === "log") {
    console.log(JSON.stringify({ type: "license_email", to: email, licenseCode }));
    return { id: "log" };
  }
  if (!env.RESEND_API_KEY || !env.RESEND_FROM) throw new Error("RESEND_API_KEY and RESEND_FROM are required");

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      from: env.RESEND_FROM,
      to: [email],
      reply_to: env.RESEND_REPLY_TO ?? "ruwin_211@126.com",
      subject: `${appName} 授权码`,
      text,
      html
    })
  });
  const data = await response.json<JsonObject>().catch((): JsonObject => ({}));
  if (!response.ok) throw new Error(`Resend email failed: ${JSON.stringify(data)}`);
  return { id: stringValue(data.id) ?? "resend" };
}

async function fetchPaddleCustomerEmail(env: Env, customerID: string): Promise<string | null> {
  const baseURL = (env.PADDLE_API_BASE_URL ?? "https://api.paddle.com").replace(/\/+$/, "");
  const response = await fetch(`${baseURL}/customers/${encodeURIComponent(customerID)}`, {
    headers: {
      Authorization: `Bearer ${env.PADDLE_API_KEY}`,
      Accept: "application/json"
    }
  });
  if (!response.ok) return null;
  const payload = await response.json<JsonObject>();
  return findEmail(objectValue(payload.data) ?? payload);
}

async function signedActivationToken(env: Env, payload: JsonObject): Promise<string> {
  const body = base64URL(utf8Bytes(JSON.stringify(payload)));
  const signature = await hmacSha256Hex(env.SERVER_TOKEN_SECRET, body);
  return `${body}.${signature}`;
}

async function licenseCodeHash(code: string, env: Env): Promise<string> {
  return sha256Hex(`${env.LICENSE_HASH_PEPPER ?? ""}:${normalizeLicenseCode(code)}`);
}

async function encryptLicenseCode(code: string, env: Env): Promise<{ ciphertext: string; iv: string }> {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const key = await licenseEncryptionKey(env);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, utf8Bytes(code)));
  return { ciphertext: base64URL(ciphertext), iv: base64URL(iv) };
}

async function decryptLicenseCode(license: LicenseRow, env: Env): Promise<string | null> {
  if (!license.license_code_ciphertext || !license.license_code_iv) return null;
  const key = await licenseEncryptionKey(env);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64ToBytes(license.license_code_iv) },
    key,
    base64ToBytes(license.license_code_ciphertext)
  );
  return new TextDecoder().decode(plaintext);
}

async function licenseEncryptionKey(env: Env): Promise<CryptoKey> {
  const secret = env.LICENSE_ENCRYPTION_KEY ?? env.LICENSE_SIGNING_KEY;
  let keyBytes = base64ToBytes(secret);
  if (keyBytes.length !== 16 && keyBytes.length !== 24 && keyBytes.length !== 32) {
    keyBytes = new Uint8Array(await crypto.subtle.digest("SHA-256", keyBytes));
  }
  return crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

function normalizeLicenseCode(code: string): string {
  return code.trim().toUpperCase().replace(/\s+/g, "");
}

async function markWebhookProcessed(env: Env, eventID: string): Promise<void> {
  await patchRows(env, "cleanmac_webhook_events", `event_id=eq.${encodeURIComponent(eventID)}`, {
    processed_at: new Date().toISOString(),
    error_message: null
  });
}

async function selectRows<T>(env: Env, path: string): Promise<T[]> {
  const response = await supabaseFetch(env, path, { method: "GET" });
  return response.json<T[]>();
}

async function first<T>(env: Env, path: string): Promise<T | null> {
  const rows = await selectRows<T>(env, `${path}${path.includes("?") ? "&" : "?"}limit=1`);
  return rows[0] ?? null;
}

async function insertRow<T = JsonObject>(env: Env, table: string, row: JsonObject): Promise<T> {
  const response = await supabaseFetch(env, table, {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(row)
  });
  return (await response.json<T[]>())[0];
}

async function upsertRow<T = JsonObject>(env: Env, table: string, conflictKey: string, row: JsonObject): Promise<T> {
  const response = await supabaseFetch(env, `${table}?on_conflict=${encodeURIComponent(conflictKey)}`, {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify(row)
  });
  return (await response.json<T[]>())[0];
}

async function patchRows(env: Env, table: string, query: string, values: JsonObject): Promise<void> {
  await supabaseFetch(env, `${table}?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(values)
  });
}

async function supabaseFetch(env: Env, path: string, init: RequestInit & { headers?: Record<string, string> }): Promise<Response> {
  const baseURL = env.SUPABASE_URL.replace(/\/+$/, "");
  const response = await fetch(`${baseURL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {})
    }
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Supabase request failed (${response.status}): ${text}`);
  }
  return response;
}

function jsonResponse(data: JsonValue, status = 200): Response {
  return corsResponse(JSON.stringify(data), status, { "Content-Type": "application/json; charset=utf-8" });
}

function corsResponse(body: BodyInit | null, status: number, headers: Record<string, string> = {}): Response {
  return new Response(body, {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type,Paddle-Signature",
      ...headers
    }
  });
}

function firstLineItem(data: JsonObject): JsonObject | null {
  const details = objectValue(data.details);
  const candidates = [details?.line_items, data.line_items, data.items];
  for (const candidate of candidates) {
    if (Array.isArray(candidate) && candidate.length > 0) return objectValue(candidate[0]) ?? null;
  }
  return null;
}

function findPriceID(item: JsonObject | null): string | null {
  if (!item) return null;
  return stringValue(item.price_id) ?? stringValue(objectValue(item.price)?.id) ?? stringValue(item.id);
}

function findProductID(item: JsonObject | null): string | null {
  if (!item) return null;
  return stringValue(item.product_id) ?? stringValue(objectValue(item.price)?.product_id) ?? stringValue(objectValue(item.product)?.id);
}

function findEmail(value: JsonObject): string | null {
  const direct = stringValue(value.email) ?? stringValue(value.customer_email);
  if (direct?.includes("@")) return direct;

  const nestedObjects = [
    objectValue(value.customer),
    objectValue(value.customer_details),
    objectValue(value.billing_details),
    objectValue(value.checkout),
    objectValue(value.custom_data)
  ];
  for (const nested of nestedObjects) {
    if (!nested) continue;
    const nestedEmail = findEmail(nested);
    if (nestedEmail) return nestedEmail;
  }
  return null;
}

function objectValue(value: JsonValue | undefined): JsonObject | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : null;
}

function stringValue(value: JsonValue | undefined): string | null {
  if (typeof value === "string" && value.trim()) return value.trim();
  if (typeof value === "number") return String(value);
  return null;
}

function requiredString(value: JsonValue | undefined, message: string): string {
  const result = stringValue(value);
  if (!result) throw new Error(message);
  return result;
}

function numberValue(value: JsonValue | undefined): number | null {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function csvSet(value: string | undefined): Set<string> {
  return new Set((value ?? "").split(",").map((item) => item.trim()).filter(Boolean));
}

function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

async function sha256Hex(value: string): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8Bytes(value))));
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  return bytesToHex(new Uint8Array(await hmacSha256(utf8Bytes(secret), utf8Bytes(message))));
}

async function hmacSha256(keyBytes: Uint8Array, message: Uint8Array): Promise<ArrayBuffer> {
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", key, message);
}

function utf8Bytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function base64ToBytes(value: string): Uint8Array {
  const normalized = value.trim().replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqualHex(left: string, right: string): boolean {
  const a = left.toLowerCase();
  const b = right.toLowerCase();
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) {
    difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return difference === 0;
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const totalLength = parts.reduce((total, part) => total + part.length, 0);
  const output = new Uint8Array(totalLength);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function maskEmail(email: string | null): string | null {
  if (!email) return null;
  const [name, domain] = email.split("@");
  if (!domain) return "***";
  return `${name.slice(0, 2)}***@${domain}`;
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;"
  }[character] ?? character));
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
