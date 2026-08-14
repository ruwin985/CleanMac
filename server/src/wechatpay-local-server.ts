import { createCipheriv, createDecipheriv, createHmac, createHash, createPrivateKey, createSign, createVerify, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import QRCode from "qrcode";

interface Env {
  PORT?: string;
  PUBLIC_BASE_URL?: string;
  SITE_DIR?: string;
  DATA_DIR?: string;
  WECHATPAY_APPID: string;
  WECHATPAY_MCH_ID: string;
  WECHATPAY_MCH_SERIAL_NO: string;
  WECHATPAY_PRIVATE_KEY: string;
  WECHATPAY_API_V3_KEY: string;
  WECHATPAY_NOTIFY_URL?: string;
  WECHATPAY_API_BASE_URL?: string;
  WECHATPAY_PLATFORM_CERT_PEM?: string;
  WECHATPAY_SKIP_NOTIFY_SIGNATURE_VERIFY?: string;
  WECHATPAY_QUERY_ON_POLL?: string;
  WECHATPAY_PRICE?: string;
  WECHATPAY_PRODUCT_NAME?: string;
  WECHATPAY_ATTACH_SECRET?: string;
  LICENSE_SIGNING_KEY: string;
  LICENSE_ENCRYPTION_KEY?: string;
  LICENSE_HASH_PEPPER?: string;
  SERVER_TOKEN_SECRET: string;
  LICENSE_MAX_DEVICES?: string;
  LICENSE_DEVICE_PRICE_MINOR?: string;
  APP_NAME?: string;
  SUPPORT_EMAIL?: string;
  RESEND_API_KEY?: string;
  RESEND_FROM?: string;
  RESEND_REPLY_TO?: string;
  EMAIL_DELIVERY_MODE?: string;
}

type JsonPrimitive = string | number | boolean | null;
type JsonValue = JsonPrimitive | JsonObject | JsonValue[];
type JsonObject = { [key: string]: JsonValue | undefined };

interface OrderRecord {
  id: string;
  provider: "wechatpay";
  outTradeNo: string;
  transactionId?: string;
  email: string | null;
  productName: string;
  amountMinor: number;
  currency: string;
  status: "pending" | "completed" | "closed";
  codeUrl?: string;
  attach: string;
  createdAt: string;
  updatedAt: string;
  paidAt?: string;
  rawNotification?: JsonObject;
}

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
  emailSendId?: string;
  lastEmailedAt?: string;
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
  orders: OrderRecord[];
  licenses: LicenseRecord[];
  processedNotifications: JsonObject[];
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
  console.log(`CleanMac local payment server listening on http://0.0.0.0:${port}`);
  console.log(`Serving site from ${siteDir}`);
  if (!env.PUBLIC_BASE_URL && !env.WECHATPAY_NOTIFY_URL) {
    console.warn("Set PUBLIC_BASE_URL after cloudflared tunnel is ready, otherwise WeChat Pay notifications cannot reach this server.");
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
    sendJSON(response, { ok: true, service: "cleanmac-local-wechatpay", runtime: "node" });
    return;
  }

  if (method === "GET" && url.pathname === "/qr") {
    await handleQRCode(url, response);
    return;
  }

  if (method === "POST" && url.pathname === "/payments/wechatpay/orders") {
    await handleCreateWeChatPayOrder(request, response);
    return;
  }

  if (method === "GET" && url.pathname.startsWith("/payments/wechatpay/orders/")) {
    await handleWeChatPayOrderStatus(url.pathname, response);
    return;
  }

  if (method === "POST" && url.pathname === "/webhooks/wechatpay") {
    await handleWeChatPayNotification(request, response);
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
    serveStatic(url.pathname, response, method === "HEAD");
    return;
  }

  sendJSON(response, { ok: false, message: "Not found" }, 404);
}

async function handleCreateWeChatPayOrder(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const body = await readJSON<JsonObject>(request);
  const email = sanitizeEmail(stringValue(body.email));
  const productName = (stringValue(body.productName) ?? env.WECHATPAY_PRODUCT_NAME ?? "CleanMac 买断授权码").slice(0, 120);
  if (!email) {
    sendJSON(response, { ok: false, message: "请填写有效邮箱，用于接收授权码。" }, 400);
    return;
  }

  const amountMinor = priceToMinor(env.WECHATPAY_PRICE ?? "2.00");
  const orderId = createOrderId();
  const attach = signAttach(orderId);
  const notifyUrl = configuredNotifyURL();
  const now = new Date().toISOString();

  const payload = {
    appid: requiredEnv("WECHATPAY_APPID"),
    mchid: requiredEnv("WECHATPAY_MCH_ID"),
    description: productName,
    out_trade_no: orderId,
    notify_url: notifyUrl,
    amount: {
      total: amountMinor,
      currency: "CNY"
    },
    attach
  };

  const apiResponse = await wechatPayJSON<{ code_url?: string }>("POST", "/v3/pay/transactions/native", payload);
  if (!apiResponse.code_url) throw new Error("微信支付下单成功但未返回 code_url");

  const order: OrderRecord = {
    id: orderId,
    provider: "wechatpay",
    outTradeNo: orderId,
    email,
    productName,
    amountMinor,
    currency: "CNY",
    status: "pending",
    codeUrl: apiResponse.code_url,
    attach,
    createdAt: now,
    updatedAt: now
  };
  store.upsertOrder(order);

  sendJSON(response, {
    ok: true,
    provider: "wechatpay",
    orderId,
    outTradeNo: orderId,
    price: minorToPrice(amountMinor),
    codeUrl: apiResponse.code_url,
    qr: apiResponse.code_url,
    payURL: apiResponse.code_url,
    qrImageURL: `/qr?data=${encodeURIComponent(apiResponse.code_url)}`,
    expiresIn: 7200
  });
}

async function handleQRCode(url: URL, response: ServerResponse): Promise<void> {
  const data = url.searchParams.get("data") ?? "";
  if (!data) {
    sendJSON(response, { ok: false, message: "Missing QR data" }, 400);
    return;
  }
  const image = await QRCode.toBuffer(data, { width: 280, margin: 1, errorCorrectionLevel: "M" });
  response.writeHead(200, defaultHeaders({ "Content-Type": "image/png", "Cache-Control": "no-store" }));
  response.end(image);
}

async function handleWeChatPayOrderStatus(pathname: string, response: ServerResponse): Promise<void> {
  const orderId = decodeURIComponent(pathname.slice("/payments/wechatpay/orders/".length));
  const order = store.findOrder(orderId);
  if (!order) {
    sendJSON(response, { ok: false, message: "订单不存在" }, 404);
    return;
  }

  if (order.status === "pending" && env.WECHATPAY_QUERY_ON_POLL !== "false") {
    await syncWeChatPayOrderStatus(order).catch((error) => console.warn("syncWeChatPayOrderStatus failed", error));
  }

  const license = store.findLicenseByOrder(orderId);
  const licenseCode = license ? decryptLicenseCode(license) : null;
  sendJSON(response, {
    ok: true,
    provider: "wechatpay",
    orderId,
    status: order.status,
    email: maskEmail(order.email),
    licenseCode
  });
}

async function handleWeChatPayNotification(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const rawBody = await readText(request);
  verifyWeChatPayNotificationSignature(request, rawBody);
  const notification = JSON.parse(rawBody) as JsonObject;
  const resource = objectValue(notification.resource);
  if (!resource) throw new Error("微信支付通知缺少 resource");

  const plainText = decryptWeChatPayResource(resource);
  const transaction = JSON.parse(plainText) as JsonObject;
  const eventId = stringValue(notification.id) ?? stringValue(transaction.transaction_id) ?? createOrderId();

  if (store.isNotificationProcessed(eventId)) {
    sendJSON(response, { code: "SUCCESS", message: "成功" });
    return;
  }

  const tradeState = stringValue(transaction.trade_state);
  const outTradeNo = requiredString(transaction.out_trade_no, "微信支付通知缺少 out_trade_no");
  const attach = stringValue(transaction.attach) ?? "";
  verifyAttach(outTradeNo, attach);

  const order = store.findOrder(outTradeNo) ?? orderFromNotification(transaction, attach);
  verifyTransactionForOrder(transaction, order, true);
  order.transactionId = stringValue(transaction.transaction_id) ?? order.transactionId;
  order.rawNotification = transaction;
  order.updatedAt = new Date().toISOString();

  if (tradeState === "SUCCESS") {
    order.status = "completed";
    order.paidAt = stringValue(transaction.success_time) ?? new Date().toISOString();
    const amount = objectValue(transaction.amount);
    const total = numberValue(amount?.total);
    if (total && total > 0) order.amountMinor = total;
    store.upsertOrder(order);
    const license = await issueLicenseForOrder(order);
    store.markNotificationProcessed({ id: eventId, eventType: stringValue(notification.event_type) ?? "TRANSACTION.SUCCESS", outTradeNo, processedAt: new Date().toISOString() });
    await sendLicenseEmail(order, license).catch((error) => console.error("sendLicenseEmail failed", error));
  } else {
    order.status = tradeState === "CLOSED" ? "closed" : order.status;
    store.upsertOrder(order);
    store.markNotificationProcessed({ id: eventId, eventType: stringValue(notification.event_type) ?? "TRANSACTION.UPDATED", outTradeNo, processedAt: new Date().toISOString() });
  }

  sendJSON(response, { code: "SUCCESS", message: "成功" });
}

async function syncWeChatPayOrderStatus(order: OrderRecord): Promise<void> {
  const mchId = requiredEnv("WECHATPAY_MCH_ID");
  const path = `/v3/pay/transactions/out-trade-no/${encodeURIComponent(order.outTradeNo)}?mchid=${encodeURIComponent(mchId)}`;
  const transaction = await wechatPayJSON<JsonObject>("GET", path);
  const tradeState = stringValue(transaction.trade_state);
  if (!tradeState || tradeState === "NOTPAY" || tradeState === "USERPAYING") return;

  verifyTransactionForOrder(transaction, order, false);
  order.transactionId = stringValue(transaction.transaction_id) ?? order.transactionId;
  order.rawNotification = transaction;
  order.updatedAt = new Date().toISOString();

  if (tradeState === "SUCCESS") {
    order.status = "completed";
    order.paidAt = stringValue(transaction.success_time) ?? order.paidAt ?? new Date().toISOString();
    store.upsertOrder(order);
    const license = await issueLicenseForOrder(order);
    await sendLicenseEmail(order, license).catch((error) => console.error("sendLicenseEmail failed", error));
    return;
  }

  if (["CLOSED", "REVOKED", "PAYERROR"].includes(tradeState)) {
    order.status = "closed";
    store.upsertOrder(order);
  }
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
    sendJSON(response, { valid: false, message: "授权码不存在或尚未同步" }, 404);
    return;
  }
  if (license.status !== "active") {
    sendJSON(response, { valid: false, message: "授权码已停用，请联系支持" }, 403);
    return;
  }

  const order = store.findOrder(license.orderId);
  if (!order || order.status !== "completed") {
    sendJSON(response, { valid: false, message: "订单状态无效，请联系支持" }, 403);
    return;
  }

  const deviceHash = sha256Hex(deviceId);
  const existingActivation = license.activations.find((activation) => activation.deviceIdHash === deviceHash);
  const maxDevices = maxDevicesForOrder(order);
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
    sendJSON(response, { valid: false, message: "授权码已停用，请联系支持" }, 403);
    return;
  }
  if (license.orderId !== transactionId) {
    sendJSON(response, { valid: false, message: "授权凭证与订单不匹配，请重新激活" }, 403);
    return;
  }
  const order = store.findOrder(license.orderId);
  if (!order || order.status !== "completed") {
    sendJSON(response, { valid: false, message: "订单状态无效，请联系支持" }, 403);
    return;
  }

  const activation = license.activations.find((item) => item.deviceIdHash === currentDeviceHash);
  if (!activation) {
    sendJSON(response, { valid: false, message: "当前设备未激活，请重新输入授权码" }, 403);
    return;
  }
  activation.lastSeenAt = new Date().toISOString();
  store.upsertLicense(license);

  sendJSON(response, { valid: true, maxDevices: maxDevicesForOrder(order) });
}

async function wechatPayJSON<T>(method: "GET" | "POST", path: string, payload?: JsonObject): Promise<T> {
  const body = payload ? JSON.stringify(payload) : "";
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const nonce = randomBytes(16).toString("hex");
  const message = `${method}\n${path}\n${timestamp}\n${nonce}\n${body}\n`;
  const signature = signRSA(message);
  const mchId = requiredEnv("WECHATPAY_MCH_ID");
  const serialNo = requiredEnv("WECHATPAY_MCH_SERIAL_NO");
  const token = `WECHATPAY2-SHA256-RSA2048 mchid="${mchId}",nonce_str="${nonce}",signature="${signature}",timestamp="${timestamp}",serial_no="${serialNo}"`;
  const baseURL = (env.WECHATPAY_API_BASE_URL ?? "https://api.mch.weixin.qq.com").replace(/\/+$/, "");
  const apiResponse = await fetch(`${baseURL}${path}`, {
    method,
    headers: {
      Authorization: token,
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "CleanMacPaymentServer/1.0"
    },
    body: method === "POST" ? body : undefined
  });

  const text = await apiResponse.text();
  if (!apiResponse.ok) {
    throw new Error(`微信支付接口失败 (${apiResponse.status}): ${text}`);
  }
  return text ? JSON.parse(text) as T : {} as T;
}

function verifyWeChatPayNotificationSignature(request: IncomingMessage, rawBody: string): void {
  const timestamp = headerValue(request, "wechatpay-timestamp");
  const nonce = headerValue(request, "wechatpay-nonce");
  const signature = headerValue(request, "wechatpay-signature");
  if (!timestamp || !nonce || !signature) throw new Error("微信支付通知缺少签名头");
  if (env.WECHATPAY_SKIP_NOTIFY_SIGNATURE_VERIFY === "true") return;
  if (!env.WECHATPAY_PLATFORM_CERT_PEM) {
    throw new Error("缺少 WECHATPAY_PLATFORM_CERT_PEM，无法验证微信支付通知签名");
  }

  const message = `${timestamp}\n${nonce}\n${rawBody}\n`;
  const verifier = createVerify("RSA-SHA256");
  verifier.update(message);
  verifier.end();
  const ok = verifier.verify(env.WECHATPAY_PLATFORM_CERT_PEM.replace(/\\n/g, "\n"), signature, "base64");
  if (!ok) throw new Error("微信支付通知签名验证失败");
}

function verifyTransactionForOrder(transaction: JsonObject, order: OrderRecord, requireAttach: boolean): void {
  const outTradeNo = requiredString(transaction.out_trade_no, "微信支付交易缺少 out_trade_no");
  if (outTradeNo !== order.outTradeNo) throw new Error("微信支付交易订单号不匹配");

  const appid = requiredString(transaction.appid, "微信支付交易缺少 appid");
  if (appid !== requiredEnv("WECHATPAY_APPID")) throw new Error("微信支付交易 appid 不匹配");

  const mchid = requiredString(transaction.mchid, "微信支付交易缺少 mchid");
  if (mchid !== requiredEnv("WECHATPAY_MCH_ID")) throw new Error("微信支付交易商户号不匹配");

  const attach = stringValue(transaction.attach);
  if (attach) {
    if (attach !== order.attach) throw new Error("微信支付交易 attach 不匹配");
    verifyAttach(outTradeNo, attach);
  } else if (requireAttach) {
    throw new Error("微信支付交易缺少 attach");
  }

  const amount = objectValue(transaction.amount);
  const total = numberValue(amount?.total);
  if (total !== null && total !== order.amountMinor) throw new Error("微信支付交易金额不匹配");
}

function decryptWeChatPayResource(resource: JsonObject): string {
  const algorithm = stringValue(resource.algorithm);
  if (algorithm !== "AEAD_AES_256_GCM") throw new Error(`不支持的微信支付通知加密算法：${algorithm ?? "missing"}`);
  const nonce = requiredString(resource.nonce, "微信支付通知缺少 nonce");
  const associatedData = stringValue(resource.associated_data) ?? "";
  const ciphertext = requiredString(resource.ciphertext, "微信支付通知缺少 ciphertext");
  const encrypted = Buffer.from(ciphertext, "base64");
  if (encrypted.length <= 16) throw new Error("微信支付通知密文无效");
  const authTag = encrypted.subarray(encrypted.length - 16);
  const data = encrypted.subarray(0, encrypted.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", Buffer.from(requiredEnv("WECHATPAY_API_V3_KEY"), "utf8"), Buffer.from(nonce, "utf8"));
  decipher.setAuthTag(authTag);
  decipher.setAAD(Buffer.from(associatedData, "utf8"));
  return Buffer.concat([decipher.update(data), decipher.final()]).toString("utf8");
}

function signRSA(message: string): string {
  const key = createPrivateKey(requiredEnv("WECHATPAY_PRIVATE_KEY").replace(/\\n/g, "\n"));
  const signer = createSign("RSA-SHA256");
  signer.update(message);
  signer.end();
  return signer.sign(key, "base64");
}

async function issueLicenseForOrder(order: OrderRecord): Promise<LicenseRecord> {
  const existing = store.findLicenseByOrder(order.id);
  if (existing) return existing;

  const plainLicenseCode = generateLicenseCode();
  const encrypted = encryptLicenseCode(plainLicenseCode);
  const now = new Date().toISOString();
  const license: LicenseRecord = {
    licenseId: cryptoUUID(),
    orderId: order.id,
    outTradeNo: order.outTradeNo,
    licenseCodeHash: licenseCodeHash(plainLicenseCode),
    licenseCodeCiphertext: encrypted.ciphertext,
    licenseCodeIv: encrypted.iv,
    licenseCodePrefix: normalizeLicenseCode(plainLicenseCode).slice(0, 10),
    email: order.email,
    status: "active",
    issuedAt: now,
    activations: []
  };
  store.upsertLicense(license);
  return license;
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

async function sendLicenseEmail(order: OrderRecord, license: LicenseRecord): Promise<void> {
  const licenseCode = decryptLicenseCode(license);
  const email = order.email;
  if (license.lastEmailedAt) return;
  if (!email || !licenseCode) return;
  const mode = env.EMAIL_DELIVERY_MODE ?? (env.RESEND_API_KEY && env.RESEND_FROM ? "resend" : "log");
  const appName = env.APP_NAME ?? "CleanMac";
  const supportEmail = env.SUPPORT_EMAIL ?? env.RESEND_REPLY_TO ?? "support@ruwin.cn";

  if (mode === "log") {
    console.log(JSON.stringify({ type: "license_email", to: email, licenseCode }));
    license.lastEmailedAt = new Date().toISOString();
    license.emailSendId = "log";
    store.upsertLicense(license);
    return;
  }

  if (!env.RESEND_API_KEY || !env.RESEND_FROM) return;
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      from: env.RESEND_FROM,
      to: email,
      reply_to: env.RESEND_REPLY_TO ?? supportEmail,
      subject: `${appName} 授权码`,
      text: [
        `你的授权码：${licenseCode}`,
        "",
        `订单号：${order.outTradeNo}`,
        "请打开 CleanMac，在授权窗口粘贴此授权码完成激活。",
        "",
        `如需帮助，请联系 ${supportEmail}`
      ].join("\n"),
      html: `
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.6;color:#1d1d1f">
          <h2>${escapeHTML(appName)} 授权码</h2>
          <p>你的授权码：</p>
          <p style="font-size:20px;font-weight:700;letter-spacing:1px;background:#f5f5f7;padding:14px 16px;border-radius:12px;display:inline-block">${escapeHTML(licenseCode)}</p>
          <p>请打开 CleanMac，在授权窗口粘贴此授权码完成激活。</p>
          <p>订单号：${escapeHTML(order.outTradeNo)}</p>
          <p>如需帮助，请联系 ${escapeHTML(supportEmail)}</p>
        </div>`
    })
  });
  if (!response.ok) throw new Error(`Resend failed (${response.status}): ${await response.text()}`);
  const result = await response.json().catch(() => ({})) as JsonObject;
  license.lastEmailedAt = new Date().toISOString();
  license.emailSendId = stringValue(result.id) ?? "resend";
  store.upsertLicense(license);
}

function encryptLicenseCode(code: string): { ciphertext: string; iv: string } {
  const key = licenseEncryptionKey();
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(code, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return { ciphertext: Buffer.concat([encrypted, tag]).toString("base64"), iv: iv.toString("base64") };
}

function decryptLicenseCode(license: LicenseRecord): string | null {
  try {
    const key = licenseEncryptionKey();
    const iv = Buffer.from(license.licenseCodeIv, "base64");
    const encrypted = Buffer.from(license.licenseCodeCiphertext, "base64");
    const tag = encrypted.subarray(encrypted.length - 16);
    const data = encrypted.subarray(0, encrypted.length - 16);
    const decipher = createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(data), decipher.final()]).toString("utf8");
  } catch {
    return null;
  }
}

function licenseEncryptionKey(): Buffer {
  const secret = env.LICENSE_ENCRYPTION_KEY ?? env.LICENSE_SIGNING_KEY;
  const direct = base64ToBuffer(secret);
  if (direct.length === 32) return direct;
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
  const [payloadPart, signaturePart] = token.split(".");
  if (!payloadPart || !signaturePart) return null;
  const expectedSignature = createHmac("sha256", requiredEnv("SERVER_TOKEN_SECRET")).update(payloadPart).digest();
  const actualSignature = base64URLDecode(signaturePart);
  if (!constantTimeEquals(expectedSignature, actualSignature)) return null;
  const payload = JSON.parse(base64URLDecode(payloadPart).toString("utf8")) as JsonObject;
  const expiresAt = numberValue(payload.expiresAt);
  if (!expiresAt || expiresAt < Math.floor(Date.now() / 1000)) return null;
  return payload;
}

function orderFromNotification(transaction: JsonObject, attach: string): OrderRecord {
  const outTradeNo = requiredString(transaction.out_trade_no, "微信支付通知缺少 out_trade_no");
  const amount = objectValue(transaction.amount);
  const payerTotal = numberValue(amount?.payer_total ?? amount?.total) ?? priceToMinor(env.WECHATPAY_PRICE ?? "2.00");
  const email = emailFromAttach(outTradeNo, attach);
  const now = new Date().toISOString();
  return {
    id: outTradeNo,
    provider: "wechatpay",
    outTradeNo,
    email,
    productName: env.WECHATPAY_PRODUCT_NAME ?? "CleanMac 买断授权码",
    amountMinor: payerTotal,
    currency: stringValue(amount?.currency) ?? "CNY",
    status: "pending",
    attach,
    createdAt: now,
    updatedAt: now
  };
}

function signAttach(orderId: string): string {
  const payload = base64URLEncode(Buffer.from(JSON.stringify({ orderId })));
  const secret = env.WECHATPAY_ATTACH_SECRET ?? env.SERVER_TOKEN_SECRET;
  const signature = createHmac("sha256", secret).update(payload).digest("hex").slice(0, 24);
  return `${payload}.${signature}`;
}

function verifyAttach(orderId: string, attach: string): void {
  if (!attach) throw new Error("微信支付通知缺少 attach");
  const [payload, signature] = attach.split(".");
  if (!payload || !signature) throw new Error("微信支付通知 attach 格式无效");
  const secret = env.WECHATPAY_ATTACH_SECRET ?? env.SERVER_TOKEN_SECRET;
  const expected = createHmac("sha256", secret).update(payload).digest("hex").slice(0, 24);
  if (!safeEqualString(signature, expected)) throw new Error("微信支付通知 attach 验证失败");
  const parsed = JSON.parse(base64URLDecode(payload).toString("utf8")) as JsonObject;
  if (stringValue(parsed.orderId) !== orderId) throw new Error("微信支付通知订单号与 attach 不匹配");
}

function emailFromAttach(orderId: string, attach: string): string | null {
  try {
    verifyAttach(orderId, attach);
    const [payload] = attach.split(".");
    const parsed = JSON.parse(base64URLDecode(payload).toString("utf8")) as JsonObject;
    return sanitizeEmail(stringValue(parsed.email));
  } catch {
    return null;
  }
}

function configuredNotifyURL(): string {
  if (env.WECHATPAY_NOTIFY_URL?.trim()) return env.WECHATPAY_NOTIFY_URL.trim();
  const baseURL = env.PUBLIC_BASE_URL?.trim().replace(/\/+$/, "");
  if (!baseURL) throw new Error("缺少 PUBLIC_BASE_URL 或 WECHATPAY_NOTIFY_URL，无法设置微信支付回调地址");
  return `${baseURL}/webhooks/wechatpay`;
}

function maxDevicesForOrder(order: OrderRecord): number {
  if (order.amountMinor > 0) return Math.max(1, Math.floor(order.amountMinor / devicePriceMinor()));
  return positiveInteger(env.LICENSE_MAX_DEVICES, 1);
}

function devicePriceMinor(): number {
  return positiveInteger(env.LICENSE_DEVICE_PRICE_MINOR, 200);
}

function serveStatic(pathname: string, response: ServerResponse, headOnly: boolean): void {
  const decodedPath = decodeURIComponent(pathname);
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
  const headers = defaultHeaders({ "Content-Type": contentType(filePath) });
  response.writeHead(200, headers);
  if (!headOnly) createReadStream(filePath).pipe(response);
  else response.end();
}

class LocalStore {
  private readonly filePath: string;
  private data: StoreData;

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true });
    this.filePath = join(dataDir, "wechatpay-store.json");
    this.data = this.read();
  }

  findOrder(orderId: string): OrderRecord | null {
    return this.data.orders.find((order) => order.id === orderId || order.outTradeNo === orderId) ?? null;
  }

  upsertOrder(order: OrderRecord): void {
    const index = this.data.orders.findIndex((item) => item.id === order.id);
    if (index >= 0) this.data.orders[index] = order;
    else this.data.orders.push(order);
    this.write();
  }

  findLicenseByOrder(orderId: string): LicenseRecord | null {
    return this.data.licenses.find((license) => license.orderId === orderId || license.outTradeNo === orderId) ?? null;
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

  isNotificationProcessed(id: string): boolean {
    return this.data.processedNotifications.some((event) => stringValue(event.id) === id);
  }

  markNotificationProcessed(event: JsonObject): void {
    if (!this.isNotificationProcessed(requiredString(event.id, "missing event id"))) {
      this.data.processedNotifications.push(event);
      this.write();
    }
  }

  private read(): StoreData {
    if (!existsSync(this.filePath)) return { orders: [], licenses: [], processedNotifications: [] };
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
    "Access-Control-Allow-Headers": "Content-Type,Wechatpay-Timestamp,Wechatpay-Nonce,Wechatpay-Signature,Wechatpay-Serial",
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

function priceToMinor(price: string): number {
  const normalized = price.trim();
  if (!/^\d+(\.\d{1,2})?$/.test(normalized)) throw new Error(`无效价格：${price}`);
  const [yuan, cents = ""] = normalized.split(".");
  return Number(yuan) * 100 + Number(cents.padEnd(2, "0"));
}

function minorToPrice(minor: number): string {
  return (minor / 100).toFixed(2);
}

function createOrderId(): string {
  const timestamp = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
  return `CM${timestamp}${randomBytes(5).toString("hex").toUpperCase()}`;
}

function sanitizeEmail(value: string | null): string | null {
  if (!value) return null;
  const email = value.trim().toLowerCase();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : null;
}

function maskEmail(email: string | null): string | null {
  if (!email) return null;
  const [name, domain] = email.split("@");
  if (!domain) return email;
  const visible = name.slice(0, Math.min(2, name.length));
  return `${visible}${"*".repeat(Math.max(1, name.length - visible.length))}@${domain}`;
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

function escapeHTML(value: string): string {
  return value.replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;"
  }[character] ?? character));
}
