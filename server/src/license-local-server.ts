import { createCipheriv, createDecipheriv, createHmac, createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

interface Env {
  PORT?: string;
  SITE_DIR?: string;
  DATA_DIR?: string;
  LICENSE_SIGNING_KEY: string;
  LICENSE_ENCRYPTION_KEY?: string;
  LICENSE_HASH_PEPPER?: string;
  SERVER_TOKEN_SECRET: string;
  LICENSE_MAX_DEVICES?: string;
  APP_NAME?: string;
  SUPPORT_EMAIL?: string;
  PURCHASE_URL?: string;
  ADMIN_TOKEN?: string;
}

type JsonPrimitive = string | number | boolean | null;
type JsonValue = JsonPrimitive | JsonObject | JsonValue[];
type JsonObject = { [key: string]: JsonValue | undefined };

interface LicenseRecord {
  licenseId: string;
  orderId: string;
  outTradeNo: string;
  licenseCodeHash: string;
  licenseCodeCiphertext: string;
  licenseCodeIv: string;
  licenseCodePrefix: string;
  email: string | null;
  status: "active" | "revoked";
  issuedAt: string;
  activations: ActivationRecord[];
  source?: "manual";
  note?: string | null;
  customerName?: string | null;
  taobaoOrderId?: string | null;
}

interface ActivationRecord {
  deviceIdHash: string;
  appVersion?: string | null;
  buildNumber?: string | null;
  platform?: string | null;
  activatedAt: string;
  lastSeenAt: string;
}

interface StoreData {
  licenses: LicenseRecord[];
}

interface ActivationRequest {
  licenseCode?: string;
  deviceId?: string;
  appVersion?: string;
  buildNumber?: string;
  platform?: string;
}

interface VerificationRequest {
  token?: string;
  deviceId?: string;
}

interface ManualLicenseRequest {
  email?: string;
  customerName?: string;
  taobaoOrderId?: string;
  note?: string;
  count?: number;
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = resolve(__filename, "..");
const projectRoot = resolve(__dirname, "../..");
const licenseAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const licenseVersion = 3;
const licenseContext = "CleanMac.short-license.v3";
const secondsPerDay = 86400;
const jsonContentType = "application/json; charset=utf-8";

const env = loadEnv();
const port = positiveInteger(env.PORT, 1314);
const siteDir = resolve(env.SITE_DIR ?? join(projectRoot, "site", "public"));
let store: LocalStore;

const server = createServer((request, response) => {
  handleRequest(request, response).catch((error) => {
    console.error(error);
    sendJSON(response, { ok: false, message: errorMessage(error) }, 500);
  });
});

server.listen(port, "0.0.0.0", () => {
  console.log(`CleanMac license server listening on http://0.0.0.0:${port}`);
  console.log(`Serving site from ${siteDir}`);
  if (!env.ADMIN_TOKEN) {
    console.warn("ADMIN_TOKEN is not set; /admin/licenses is disabled until you configure it.");
  }
});

async function handleRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const method = request.method ?? "GET";
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? `localhost:${port}`}`);

  if (method === "OPTIONS") {
    sendNoContent(response, 204);
    return;
  }

  if (method === "GET" && url.pathname === "/health") {
    sendJSON(response, {
      ok: true,
      service: "cleanmac-license-local",
      runtime: "node",
      purchaseURL: env.PURCHASE_URL ?? null
    });
    return;
  }

  if (method === "POST" && url.pathname === "/admin/licenses") {
    await handleCreateManualLicenses(request, response);
    return;
  }

  if (method === "POST" && url.pathname === "/licenses/activate") {
    await handleLicenseActivation(request, response);
    return;
  }

  if (method === "POST" && url.pathname === "/licenses/verify") {
    await handleLicenseVerification(request, response);
    return;
  }

  if (method === "GET" || method === "HEAD") {
    serveStatic(url.pathname, request, response, method === "HEAD");
    return;
  }

  sendJSON(response, { ok: false, message: "Not found" }, 404);
}

async function handleCreateManualLicenses(request: IncomingMessage, response: ServerResponse): Promise<void> {
  requireAdmin(request);
  const body = await readJSON<ManualLicenseRequest>(request);
  const count = positiveInteger(body.count ? String(body.count) : undefined, 1);
  if (count > 50) {
    sendJSON(response, { ok: false, message: "单次最多生成 50 个授权码" }, 400);
    return;
  }

  const licenses = Array.from({ length: count }, () => issueManualLicense({
    email: sanitizeEmail(body.email ?? null),
    customerName: trimmedOrNull(body.customerName),
    taobaoOrderId: trimmedOrNull(body.taobaoOrderId),
    note: trimmedOrNull(body.note)
  }));

  sendJSON(response, {
    ok: true,
    licenses: licenses.map(({ record, licenseCode }) => ({
      licenseId: record.licenseId,
      licenseCode,
      prefix: record.licenseCodePrefix,
      issuedAt: record.issuedAt,
      taobaoOrderId: record.taobaoOrderId,
      email: record.email
    }))
  });
}

async function handleLicenseActivation(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const body = await readJSON<ActivationRequest>(request);
  const licenseCode = normalizeLicenseCode(body.licenseCode ?? "");
  const deviceId = (body.deviceId ?? "").trim();
  if (!licenseCode) {
    sendJSON(response, { valid: false, message: "授权码不能为空" }, 400);
    return;
  }
  if (!deviceId) {
    sendJSON(response, { valid: false, message: "设备标识不能为空" }, 400);
    return;
  }

  const license = store.findLicenseByCodeHash(licenseCodeHash(licenseCode));
  if (!license) {
    sendJSON(response, { valid: false, message: "授权码不存在，请确认已从客服获取有效授权码" }, 404);
    return;
  }
  if (license.status !== "active") {
    sendJSON(response, { valid: false, message: "授权码已停用，请联系客服" }, 403);
    return;
  }

  const deviceHash = sha256Hex(deviceId);
  const existingActivation = license.activations.find((activation) => activation.deviceIdHash === deviceHash);
  const maxDevices = maxDevicesForLicense();
  if (!existingActivation && license.activations.length >= maxDevices) {
    sendJSON(response, { valid: false, message: `该授权码已达到 ${maxDevices} 台设备激活上限` }, 403);
    return;
  }

  const now = new Date().toISOString();
  if (existingActivation) {
    existingActivation.lastSeenAt = now;
    existingActivation.appVersion = body.appVersion ?? existingActivation.appVersion ?? null;
    existingActivation.buildNumber = body.buildNumber ?? existingActivation.buildNumber ?? null;
    existingActivation.platform = body.platform ?? existingActivation.platform ?? null;
  } else {
    license.activations.push({
      deviceIdHash: deviceHash,
      appVersion: body.appVersion ?? null,
      buildNumber: body.buildNumber ?? null,
      platform: body.platform ?? null,
      activatedAt: now,
      lastSeenAt: now
    });
  }
  store.upsertLicense(license);

  const token = signedActivationToken({
    licenseId: license.licenseId,
    transactionId: license.orderId,
    deviceIdHash: deviceHash,
    issuedAt: Math.floor(Date.now() / 1000),
    expiresAt: Math.floor(Date.now() / 1000) + 90 * 24 * 60 * 60
  });

  sendJSON(response, {
    valid: true,
    token,
    maxDevices,
    license: {
      licenseId: license.licenseId,
      product: env.APP_NAME ?? "CleanMac",
      transactionId: license.orderId,
      email: license.email,
      issuedAt: license.issuedAt
    }
  });
}

async function handleLicenseVerification(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const body = await readJSON<VerificationRequest>(request);
  const token = (body.token ?? "").trim();
  const deviceId = (body.deviceId ?? "").trim();
  if (!token) {
    sendJSON(response, { valid: false, message: "授权凭证不能为空" }, 400);
    return;
  }
  if (!deviceId) {
    sendJSON(response, { valid: false, message: "设备标识不能为空" }, 400);
    return;
  }

  const tokenPayload = activationTokenPayload(token);
  if (!tokenPayload) {
    sendJSON(response, { valid: false, message: "授权凭证无效，请重新激活" }, 403);
    return;
  }

  const licenseId = stringValue(tokenPayload.licenseId);
  const transactionId = stringValue(tokenPayload.transactionId);
  const tokenDeviceHash = stringValue(tokenPayload.deviceIdHash);
  const currentDeviceHash = sha256Hex(deviceId);
  if (!licenseId || !transactionId || !tokenDeviceHash || tokenDeviceHash !== currentDeviceHash) {
    sendJSON(response, { valid: false, message: "授权凭证与当前设备不匹配，请重新激活" }, 403);
    return;
  }

  const license = store.findLicenseById(licenseId);
  if (!license || license.status !== "active") {
    sendJSON(response, { valid: false, message: "授权码已停用，请联系客服" }, 403);
    return;
  }
  if (license.orderId !== transactionId) {
    sendJSON(response, { valid: false, message: "授权凭证订单不匹配，请重新激活" }, 403);
    return;
  }

  const activation = license.activations.find((item) => item.deviceIdHash === currentDeviceHash);
  if (!activation) {
    sendJSON(response, { valid: false, message: "当前设备未激活，请重新输入授权码" }, 403);
    return;
  }
  activation.lastSeenAt = new Date().toISOString();
  store.upsertLicense(license);

  sendJSON(response, { valid: true, maxDevices: maxDevicesForLicense() });
}

function issueManualLicense(input: { email: string | null; customerName: string | null; taobaoOrderId: string | null; note: string | null }): { record: LicenseRecord; licenseCode: string } {
  const licenseCode = generateLicenseCode();
  const encrypted = encryptLicenseCode(licenseCode);
  const now = new Date().toISOString();
  const orderId = input.taobaoOrderId ? `taobao-${input.taobaoOrderId}` : `manual-${new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}-${randomBytes(3).toString("hex")}`;
  const record: LicenseRecord = {
    licenseId: cryptoUUID(),
    orderId,
    outTradeNo: orderId,
    licenseCodeHash: licenseCodeHash(licenseCode),
    licenseCodeCiphertext: encrypted.ciphertext,
    licenseCodeIv: encrypted.iv,
    licenseCodePrefix: normalizeLicenseCode(licenseCode).slice(0, 10),
    email: input.email,
    status: "active",
    issuedAt: now,
    activations: [],
    source: "manual",
    note: input.note,
    customerName: input.customerName,
    taobaoOrderId: input.taobaoOrderId
  };
  store.upsertLicense(record);
  return { record, licenseCode };
}

function generateLicenseCode(): string {
  const signedPayload = Buffer.alloc(8);
  signedPayload[0] = licenseVersion;
  const issuedAtDay = Math.floor(Date.now() / 1000 / secondsPerDay);
  signedPayload[1] = (issuedAtDay >> 8) & 0xff;
  signedPayload[2] = issuedAtDay & 0xff;
  randomBytes(5).copy(signedPayload, 3);
  const signingKey = base64ToBuffer(requiredEnv("LICENSE_SIGNING_KEY"));
  if (signingKey.length < 16) throw new Error("LICENSE_SIGNING_KEY must be at least 16 bytes");
  const tag = createHmac("sha256", signingKey).update(Buffer.concat([Buffer.from(licenseContext, "utf8"), signedPayload])).digest().subarray(0, 5);
  return groupedLicenseCode(Buffer.concat([signedPayload, tag]));
}

function groupedLicenseCode(payload: Buffer): string {
  const encoded = base32Encode(payload);
  const groups = encoded.match(/.{1,7}/g) ?? [encoded];
  return `CM-${groups.join("-")}`;
}

function base32Encode(bytes: Buffer): string {
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

function encryptLicenseCode(code: string): { ciphertext: string; iv: string } {
  const key = licenseEncryptionKey();
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(code, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return { ciphertext: Buffer.concat([encrypted, tag]).toString("base64"), iv: iv.toString("base64") };
}

function licenseEncryptionKey(): Buffer {
  const secret = env.LICENSE_ENCRYPTION_KEY ?? env.LICENSE_SIGNING_KEY;
  return createHash("sha256").update(secret).digest();
}

function licenseCodeHash(code: string): string {
  return sha256Hex(`${env.LICENSE_HASH_PEPPER ?? ""}:${normalizeLicenseCode(code)}`);
}

function signedActivationToken(payload: JsonObject): string {
  const encodedPayload = base64URLEncode(Buffer.from(JSON.stringify(payload)));
  const signature = createHmac("sha256", requiredEnv("SERVER_TOKEN_SECRET")).update(encodedPayload).digest();
  return `${encodedPayload}.${base64URLEncode(signature)}`;
}

function activationTokenPayload(token: string): JsonObject | null {
  const [encodedPayload, signature] = token.split(".");
  if (!encodedPayload || !signature) return null;
  const expected = base64URLEncode(createHmac("sha256", requiredEnv("SERVER_TOKEN_SECRET")).update(encodedPayload).digest());
  if (!safeEqualString(signature, expected)) return null;
  const payload = JSON.parse(base64URLDecode(encodedPayload).toString("utf8")) as JsonObject;
  const expiresAt = numberValue(payload.expiresAt);
  if (expiresAt && expiresAt < Math.floor(Date.now() / 1000)) return null;
  return payload;
}

function maxDevicesForLicense(): number {
  return positiveInteger(env.LICENSE_MAX_DEVICES, 1);
}

function serveStatic(pathname: string, request: IncomingMessage, response: ServerResponse, headOnly: boolean): void {
  let decodedPath: string;
  try {
    decodedPath = decodeURIComponent(pathname);
  } catch {
    sendJSON(response, { ok: false, message: "Bad request" }, 400);
    return;
  }
  const normalizedPath = normalize(decodedPath).replace(/^(\.\.(\/|\\|$))+/, "");
  let filePath = resolve(siteDir, `.${normalizedPath}`);
  if (!filePath.startsWith(siteDir)) {
    sendJSON(response, { ok: false, message: "Forbidden" }, 403);
    return;
  }
  if (!existsSync(filePath) || statSync(filePath).isDirectory()) filePath = join(filePath, "index.html");
  if (!existsSync(filePath) || statSync(filePath).isDirectory()) filePath = join(siteDir, "index.html");
  if (!existsSync(filePath)) {
    sendJSON(response, { ok: false, message: "site/public 不存在，请先运行 Hugo 构建站点。" }, 404);
    return;
  }
  const size = statSync(filePath).size;
  const range = headerValue(request, "range");
  const headers = defaultHeaders({
    "Accept-Ranges": "bytes",
    "Content-Type": contentType(filePath)
  });

  if (range) {
    const parsedRange = parseByteRange(range, size);
    if (!parsedRange) {
      response.writeHead(416, defaultHeaders({
        "Content-Range": `bytes */${size}`,
        "Content-Type": "text/plain; charset=utf-8"
      }));
      response.end("Requested Range Not Satisfiable");
      return;
    }

    response.writeHead(206, {
      ...headers,
      "Content-Length": String(parsedRange.end - parsedRange.start + 1),
      "Content-Range": `bytes ${parsedRange.start}-${parsedRange.end}/${size}`
    });
    if (!headOnly) createReadStream(filePath, { start: parsedRange.start, end: parsedRange.end }).pipe(response);
    else response.end();
    return;
  }

  response.writeHead(200, { ...headers, "Content-Length": String(size) });
  if (!headOnly) createReadStream(filePath).pipe(response);
  else response.end();
}

function parseByteRange(range: string, size: number): { start: number; end: number } | null {
  const match = range.match(/^bytes=(\d*)-(\d*)$/);
  if (!match || size <= 0) return null;

  const [, rawStart, rawEnd] = match;
  if (!rawStart && !rawEnd) return null;

  if (!rawStart) {
    const suffixLength = Number(rawEnd);
    if (!Number.isInteger(suffixLength) || suffixLength <= 0) return null;
    return { start: Math.max(size - suffixLength, 0), end: size - 1 };
  }

  const start = Number(rawStart);
  const end = rawEnd ? Number(rawEnd) : size - 1;
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end < start || start >= size) return null;
  return { start, end: Math.min(end, size - 1) };
}

class LocalStore {
  private readonly filePath: string;
  private data: StoreData;

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true });
    this.filePath = join(dataDir, "license-store.json");
    this.data = this.read();
  }

  findLicenseByCodeHash(hash: string): LicenseRecord | null {
    return this.data.licenses.find((license) => license.licenseCodeHash === hash) ?? null;
  }

  findLicenseById(licenseId: string): LicenseRecord | null {
    return this.data.licenses.find((license) => license.licenseId === licenseId) ?? null;
  }

  upsertLicense(license: LicenseRecord): void {
    const index = this.data.licenses.findIndex((item) => item.licenseId === license.licenseId);
    if (index >= 0) this.data.licenses[index] = license;
    else this.data.licenses.push(license);
    this.write();
  }

  private read(): StoreData {
    if (!existsSync(this.filePath)) return { licenses: [] };
    return JSON.parse(readFileSync(this.filePath, "utf8")) as StoreData;
  }

  private write(): void {
    writeFileSync(this.filePath, `${JSON.stringify(this.data, null, 2)}\n`);
  }
}

store = new LocalStore(resolve(env.DATA_DIR ?? join(projectRoot, "server", "data")));

function loadEnv(): Env {
  for (const name of [".env", ".dev.vars"]) {
    const path = join(projectRoot, "server", name);
    if (!existsSync(path)) continue;
    const lines = readFileSync(path, "utf8").split(/\r?\n/);
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (!match) continue;
      const key = match[1];
      if (process.env[key]) continue;
      process.env[key] = unquoteEnvValue(match[2]);
    }
  }
  return process.env as unknown as Env;
}

function unquoteEnvValue(value: string): string {
  const trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1).replace(/\\n/g, "\n");
  }
  return trimmed;
}

function requireAdmin(request: IncomingMessage): void {
  const token = env.ADMIN_TOKEN?.trim();
  if (!token) throw new Error("ADMIN_TOKEN 未配置，无法生成手工授权码");
  const authorization = headerValue(request, "authorization") ?? "";
  const bearerToken = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (!bearerToken || !safeEqualString(bearerToken, token)) throw new Error("管理员令牌无效");
}

async function readJSON<T>(request: IncomingMessage): Promise<T> {
  const text = await readText(request);
  return text ? JSON.parse(text) as T : {} as T;
}

function readText(request: IncomingMessage): Promise<string> {
  return new Promise((resolveText, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
    request.on("end", () => resolveText(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function sendJSON(response: ServerResponse, data: JsonValue, status = 200): void {
  response.writeHead(status, defaultHeaders({ "Content-Type": jsonContentType }));
  response.end(JSON.stringify(data));
}

function sendNoContent(response: ServerResponse, status = 204): void {
  response.writeHead(status, defaultHeaders());
  response.end();
}

function defaultHeaders(headers: Record<string, string> = {}): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    ...headers
  };
}

function contentType(filePath: string): string {
  switch (extname(filePath).toLowerCase()) {
  case ".html": return "text/html; charset=utf-8";
  case ".css": return "text/css; charset=utf-8";
  case ".js": return "application/javascript; charset=utf-8";
  case ".json": return "application/json; charset=utf-8";
  case ".png": return "image/png";
  case ".jpg":
  case ".jpeg": return "image/jpeg";
  case ".svg": return "image/svg+xml";
  case ".webp": return "image/webp";
  case ".mp4": return "video/mp4";
  case ".dmg": return "application/x-apple-diskimage";
  default: return "application/octet-stream";
  }
}

function sanitizeEmail(value: string | null): string | null {
  if (!value) return null;
  const email = value.trim().toLowerCase();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : null;
}

function trimmedOrNull(value: string | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed.slice(0, 200) : null;
}

function normalizeLicenseCode(code: string): string {
  return code.trim().toUpperCase().replace(/\s+/g, "");
}

function sha256Hex(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function base64URLEncode(value: Buffer): string {
  return value.toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function base64URLDecode(value: string): Buffer {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(normalized + "=".repeat((4 - normalized.length % 4) % 4), "base64");
}

function base64ToBuffer(value: string): Buffer {
  const normalized = value.trim().replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(normalized + "=".repeat((4 - normalized.length % 4) % 4), "base64");
}

function constantTimeEquals(left: Buffer, right: Buffer): boolean {
  return left.length === right.length && timingSafeEqual(left, right);
}

function safeEqualString(left: string, right: string): boolean {
  return constantTimeEquals(Buffer.from(left), Buffer.from(right));
}

function stringValue(value: JsonValue | undefined): string | null {
  if (typeof value === "string" && value.trim()) return value.trim();
  if (typeof value === "number") return String(value);
  return null;
}

function numberValue(value: JsonValue | undefined): number | null {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function cryptoUUID(): string {
  return randomUUID();
}

function headerValue(request: IncomingMessage, name: string): string | null {
  const value = request.headers[name.toLowerCase()];
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

function requiredEnv<K extends keyof Env>(name: K): string {
  const value = env[name];
  if (typeof value !== "string" || !value.trim()) throw new Error(`Missing ${String(name)}`);
  return value.trim();
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
