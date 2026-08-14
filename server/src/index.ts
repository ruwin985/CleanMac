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
  LICENSE_DEVICE_PRICE_MINOR?: string;
  APP_NAME?: string;
  SUPPORT_EMAIL?: string;
  PADDLE_SIGNATURE_TOLERANCE_SECONDS?: string;
  XORPAY_AID?: string;
  XORPAY_APP_SECRET?: string;
  XORPAY_API_BASE_URL?: string;
  XORPAY_NOTIFY_URL?: string;
  XORPAY_PRICE?: string;
  XORPAY_PAY_TYPE?: string;
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

interface LicenseVerificationRequest {
  token?: string;
  deviceId?: string;
}

interface XorPayCreateOrderRequest {
  email?: string;
  productName?: string;
}

interface XorPayOrderResponse {
  status?: string;
  aoid?: string;
  expire_in?: number;
  expires_in?: number;
  info?: { qr?: string };
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
      if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
        return jsonResponse({ ok: true, service: "cleanmac-license", runtime: "cloudflare-worker" });
      }
      if (request.method === "POST" && url.pathname === "/webhooks/paddle") {
        return await handlePaddleWebhook(request, env);
      }
      if (request.method === "POST" && url.pathname === "/webhooks/xorpay") {
        return await handleXorPayWebhook(request, env);
      }
      if (request.method === "POST" && url.pathname === "/payments/xorpay/orders") {
        return await handleXorPayCreateOrder(request, env);
      }
      if (request.method === "GET" && url.pathname.startsWith("/payments/xorpay/orders/")) {
        return await handleXorPayOrderStatus(url.pathname, env);
      }
      if (request.method === "POST" && url.pathname === "/licenses/activate") {
        return await handleLicenseActivation(request, env);
      }
      if (request.method === "POST" && url.pathname === "/licenses/verify") {
        return await handleLicenseVerification(request, env);
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
      paddle_transaction_id: paddleTransactionIDFromEvent(event) ?? stringValue(event.data?.id),
      payload: event as unknown as JsonObject
    });
  }

  if (isRefundRevocationEvent(event)) {
    return handlePaddleRefundRevocation(event, env, eventID);
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
      const maxDevices = maxDevicesForOrder(order, env);
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
          product_id: order.product_id,
          currency_code: order.currency_code,
          total_amount_minor: order.total_amount_minor,
          max_devices: maxDevices,
          device_price_minor: devicePriceMinor(env)
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

async function handlePaddleRefundRevocation(event: PaddleEvent, env: Env, eventID: string): Promise<Response> {
  try {
    const data = event.data ?? {};
    const transactionID = findAdjustmentTransactionID(data);
    if (!transactionID) throw new Error("Refund adjustment is missing transaction id");

    await patchRows(env, "cleanmac_orders", `paddle_transaction_id=eq.${encodeURIComponent(transactionID)}`, {
      status: "refunded",
      raw_event_id: eventID
    });

    const license = await first<LicenseRow>(env, `cleanmac_licenses?paddle_transaction_id=eq.${encodeURIComponent(transactionID)}&select=*`);
    if (!license) {
      await markWebhookProcessed(env, eventID);
      return jsonResponse({ ok: true, revoked: false, reason: "license_not_found", transactionId: transactionID });
    }

    await patchRows(env, "cleanmac_licenses", `license_id=eq.${license.license_id}`, {
      status: "refunded",
      metadata: {
        ...(license.metadata ?? {}),
        revoked_at: new Date().toISOString(),
        revoked_event_id: eventID,
        revoked_reason: adjustmentRevocationReason(data),
        refund_adjustment_id: stringValue(data.id)
      }
    });
    await deleteRows(env, "cleanmac_activations", `license_id=eq.${license.license_id}`);
    await markWebhookProcessed(env, eventID);

    return jsonResponse({ ok: true, revoked: true, licenseId: license.license_id, transactionId: transactionID });
  } catch (error) {
    await patchRows(env, "cleanmac_webhook_events", `event_id=eq.${encodeURIComponent(eventID)}`, {
      error_message: errorMessage(error)
    });
    return jsonResponse({ ok: false, message: errorMessage(error) }, 500);
  }
}

async function handleXorPayCreateOrder(request: Request, env: Env): Promise<Response> {
  const body = await request.json().catch((): XorPayCreateOrderRequest => ({})) as XorPayCreateOrderRequest;
  const email = (body.email ?? "").trim().toLowerCase();
  if (!email || !email.includes("@")) return jsonResponse({ ok: false, message: "请填写有效邮箱" }, 400);

  const aid = requiredXorPayEnv(env, "XORPAY_AID", env.XORPAY_AID);
  const appSecret = requiredXorPayEnv(env, "XORPAY_APP_SECRET", env.XORPAY_APP_SECRET);
  const baseURL = (env.XORPAY_API_BASE_URL ?? "https://xorpay.com").replace(/\/+$/, "");
  const productName = (body.productName ?? env.APP_NAME ?? "CleanMac 买断授权码").trim();
  const payType = (env.XORPAY_PAY_TYPE ?? "native").trim();
  const price = xorPayPrice(env);
  const orderID = `cm_${Date.now()}_${randomHex(6)}`;
  const notifyURL = xorPayNotifyURL(request, env);
  const sign = await md5Hex([productName, payType, price, orderID, notifyURL, appSecret].join(""));
  const params = new URLSearchParams({
    name: productName,
    pay_type: payType,
    price,
    order_id: orderID,
    order_uid: email,
    notify_url: notifyURL,
    more: JSON.stringify({ email, product: "CleanMac" }),
    sign
  });

  const response = await fetch(`${baseURL}/api/pay/${encodeURIComponent(aid)}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString()
  });
  const result = await response.json<XorPayOrderResponse>().catch((): XorPayOrderResponse => ({}));
  if (!response.ok || result.status !== "ok" || !result.info?.qr || !result.aoid) {
    return jsonResponse({ ok: false, message: xorPayErrorMessage(result.status), detail: result.status ?? response.statusText }, 502);
  }

  const transactionID = xorPayTransactionID(orderID);
  await upsertRow(env, "cleanmac_orders", "paddle_transaction_id", {
    paddle_transaction_id: transactionID,
    paddle_customer_id: result.aoid,
    customer_email: email,
    price_id: "xorpay_cleanmac_buyout",
    product_id: "cleanmac",
    currency_code: "CNY",
    total_amount_minor: yuanToMinor(price),
    status: "pending",
    raw_event_id: null,
    metadata: {
      provider: "xorpay",
      order_id: orderID,
      aoid: result.aoid,
      pay_type: payType,
      qr: result.info.qr
    }
  });

  return jsonResponse({
    ok: true,
    provider: "xorpay",
    orderId: orderID,
    transactionId: transactionID,
    aoid: result.aoid,
    price,
    qr: result.info.qr,
    payURL: result.info.qr,
    qrImageURL: `${baseURL}/qr?data=${encodeURIComponent(result.info.qr)}`,
    expiresIn: result.expire_in ?? result.expires_in ?? 7200
  });
}

async function handleXorPayOrderStatus(path: string, env: Env): Promise<Response> {
  const orderID = decodeURIComponent(path.slice("/payments/xorpay/orders/".length));
  if (!orderID) return jsonResponse({ ok: false, message: "Missing order id" }, 400);

  const transactionID = xorPayTransactionID(orderID);
  const order = await first<OrderRow>(env, `cleanmac_orders?paddle_transaction_id=eq.${encodeURIComponent(transactionID)}&select=*`);
  if (!order) return jsonResponse({ ok: false, message: "订单不存在" }, 404);

  const license = await first<LicenseRow>(env, `cleanmac_licenses?paddle_transaction_id=eq.${encodeURIComponent(transactionID)}&select=*`);
  const licenseCode = license ? await decryptLicenseCode(license, env) : null;
  return jsonResponse({
    ok: true,
    orderId: orderID,
    transactionId: transactionID,
    status: order.status,
    email: maskEmail(order.customer_email),
    licenseCode
  });
}

async function handleXorPayWebhook(request: Request, env: Env): Promise<Response> {
  const form = await request.formData();
  const aoid = formString(form, "aoid");
  const orderID = formString(form, "order_id");
  const payPrice = formString(form, "pay_price");
  const payTime = formString(form, "pay_time");
  const more = formString(form, "more");
  const detail = formString(form, "detail");
  const signature = formString(form, "sign");
  if (!aoid || !orderID || !payPrice || !payTime || !signature) return jsonResponse({ ok: false, message: "Invalid XorPay callback" }, 400);

  const appSecret = requiredXorPayEnv(env, "XORPAY_APP_SECRET", env.XORPAY_APP_SECRET);
  const expected = await md5Hex(`${aoid}${orderID}${payPrice}${payTime}${appSecret}`);
  if (!constantTimeEqualHex(signature, expected)) return jsonResponse({ ok: false, message: "Invalid XorPay callback signature" }, 403);

  const eventID = `xorpay_${aoid}`;
  const existingEvent = await first<WebhookEventRow>(env, `cleanmac_webhook_events?event_id=eq.${encodeURIComponent(eventID)}&select=event_id,event_type,processed_at`);
  if (existingEvent?.processed_at) return new Response("ok", { status: 200 });

  const payload = formDataPayload(form);
  if (!existingEvent) {
    await insertRow(env, "cleanmac_webhook_events", {
      event_id: eventID,
      event_type: "xorpay.paid",
      paddle_transaction_id: xorPayTransactionID(orderID),
      payload
    });
  }

  try {
    const order = await orderFromXorPayCallback(env, orderID, aoid, payPrice, payTime, more, detail, eventID);
    await upsertRow(env, "cleanmac_orders", "paddle_transaction_id", { ...order });
    const license = await issueLicenseForOrder(env, order, "xorpay_webhook", {
      event_id: eventID,
      aoid,
      order_id: orderID,
      pay_time: payTime,
      detail
    });
    await markWebhookProcessed(env, eventID);
    return new Response(license ? "ok" : "success", { status: 200 });
  } catch (error) {
    await patchRows(env, "cleanmac_webhook_events", `event_id=eq.${encodeURIComponent(eventID)}`, {
      error_message: errorMessage(error)
    });
    return jsonResponse({ ok: false, message: errorMessage(error) }, 500);
  }
}

async function handleLicenseActivation(request: Request, env: Env): Promise<Response> {
  const body = await request.json() as ActivationRequest;
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
  const maxDevices = maxDevicesForLicense(license, order, env);
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
    maxDevices,
    license: {
      licenseId: license.license_id,
      product: env.APP_NAME ?? "CleanMac",
      transactionId: license.paddle_transaction_id,
      email: license.customer_email,
      issuedAt: license.issued_at
    }
  });
}

async function handleLicenseVerification(request: Request, env: Env): Promise<Response> {
  const body = await request.json() as LicenseVerificationRequest;
  const token = (body.token ?? "").trim();
  const deviceId = (body.deviceId ?? "").trim();

  if (!token) return jsonResponse({ valid: false, message: "授权凭证不能为空" }, 400);
  if (!deviceId) return jsonResponse({ valid: false, message: "设备标识不能为空" }, 400);

  const tokenPayload = await activationTokenPayload(token, env);
  if (!tokenPayload) return jsonResponse({ valid: false, message: "授权凭证无效，请重新激活" }, 403);

  const licenseID = stringValue(tokenPayload.licenseId);
  const transactionID = stringValue(tokenPayload.transactionId);
  const tokenDeviceHash = stringValue(tokenPayload.deviceIdHash);
  const currentDeviceHash = await sha256Hex(deviceId);

  if (!licenseID || !transactionID || !tokenDeviceHash || tokenDeviceHash !== currentDeviceHash) {
    return jsonResponse({ valid: false, message: "授权凭证与当前设备不匹配，请重新激活" }, 403);
  }
  const license = await first<LicenseRow>(env, `cleanmac_licenses?license_id=eq.${encodeURIComponent(licenseID)}&select=*`);
  if (!license || license.status !== "active") {
    return jsonResponse({ valid: false, message: "授权码已停用，请联系支持" }, 403);
  }
  if (license.paddle_transaction_id !== transactionID) {
    return jsonResponse({ valid: false, message: "授权凭证与订单不匹配，请重新激活" }, 403);
  }

  const order = await first<OrderRow>(env, `cleanmac_orders?paddle_transaction_id=eq.${encodeURIComponent(transactionID)}&select=*`);
  if (!order || order.status !== "completed") {
    return jsonResponse({ valid: false, message: "订单状态无效，请联系支持" }, 403);
  }

  const activation = await first<{ device_id_hash: string }>(env, `cleanmac_activations?license_id=eq.${encodeURIComponent(licenseID)}&device_id_hash=eq.${currentDeviceHash}&select=device_id_hash`);
  if (!activation) {
    return jsonResponse({ valid: false, message: "当前设备授权已撤销，请重新激活或联系支持" }, 403);
  }

  await patchRows(env, "cleanmac_activations", `license_id=eq.${licenseID}&device_id_hash=eq.${currentDeviceHash}`, {
    last_seen_at: new Date().toISOString()
  });

  return jsonResponse({ valid: true, maxDevices: maxDevicesForLicense(license, order, env) });
}

async function issueLicenseForOrder(env: Env, order: OrderRow, source: string, metadata: JsonObject = {}): Promise<LicenseRow> {
  let license = await first<LicenseRow>(env, `cleanmac_licenses?paddle_transaction_id=eq.${encodeURIComponent(order.paddle_transaction_id)}&select=*`);
  let plainLicenseCode: string | null = null;

  if (!license) {
    const maxDevices = maxDevicesForOrder(order, env);
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
        source,
        ...metadata,
        price_id: order.price_id,
        product_id: order.product_id,
        currency_code: order.currency_code,
        total_amount_minor: order.total_amount_minor,
        max_devices: maxDevices,
        device_price_minor: devicePriceMinor(env)
      }
    });
  } else if (!license.last_emailed_at) {
    plainLicenseCode = await decryptLicenseCode(license, env);
  }

  if (plainLicenseCode && !license.last_emailed_at && order.customer_email) {
    const emailResult = await sendLicenseEmail(env, order, plainLicenseCode);
    await patchRows(env, "cleanmac_licenses", `license_id=eq.${license.license_id}`, {
      last_emailed_at: new Date().toISOString(),
      email_send_id: emailResult.id
    });
  }

  return license;
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

function orderFromXorPayCallback(env: Env, orderID: string, aoid: string, payPrice: string, payTime: string, more: string | null, detail: string | null, eventID: string): OrderRow {
  const expectedPrice = xorPayPrice(env);
  if (payPrice !== expectedPrice) throw new Error(`Unexpected XorPay price: ${payPrice}`);
  const parsedMore = parseJSONObject(more);
  const parsedDetail = parseJSONObject(detail);
  const email = findEmail(parsedMore ?? {}) ?? findEmail(parsedDetail ?? {});
  return {
    paddle_transaction_id: xorPayTransactionID(orderID),
    paddle_customer_id: aoid,
    customer_email: email,
    price_id: "xorpay_cleanmac_buyout",
    product_id: "cleanmac",
    currency_code: "CNY",
    total_amount_minor: yuanToMinor(payPrice),
    status: "completed",
    raw_event_id: eventID
  };
}

function xorPayTransactionID(orderID: string): string {
  return `xorpay_${orderID}`;
}

function xorPayPrice(env: Env): string {
  const rawValue = env.XORPAY_PRICE ?? "2.00";
  const amount = Number(rawValue);
  if (!Number.isFinite(amount) || amount <= 0) throw new Error("XORPAY_PRICE must be a positive amount like 2.00");
  return amount.toFixed(2);
}

function xorPayNotifyURL(request: Request, env: Env): string {
  if (env.XORPAY_NOTIFY_URL?.trim()) return env.XORPAY_NOTIFY_URL.trim();
  const url = new URL(request.url);
  const suffix = "/payments/xorpay/orders";
  url.pathname = url.pathname.endsWith(suffix) ? `${url.pathname.slice(0, -suffix.length)}/webhooks/xorpay` : "/webhooks/xorpay";
  url.search = "";
  return url.toString();
}

function requiredXorPayEnv(name: string, value: string | undefined): string;
function requiredXorPayEnv(_env: Env, name: string, value: string | undefined): string;
function requiredXorPayEnv(firstArg: Env | string, secondArg: string | undefined, thirdArg?: string): string {
  const name = typeof firstArg === "string" ? firstArg : secondArg ?? "XorPay secret";
  const value = typeof firstArg === "string" ? secondArg : thirdArg;
  if (!value?.trim()) throw new Error(`Missing ${name}`);
  return value.trim();
}

function formString(form: FormData, key: string): string | null {
  const value = form.get(key);
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function formDataPayload(form: FormData): JsonObject {
  const payload: JsonObject = {};
  for (const [key, value] of form.entries()) {
    if (typeof value === "string") payload[key] = value;
  }
  return payload;
}

function parseJSONObject(value: string | null): JsonObject | null {
  if (!value) return null;
  try {
    const parsed = JSON.parse(value) as JsonValue;
    return objectValue(parsed);
  } catch {
    return null;
  }
}

function yuanToMinor(value: string): number {
  return Math.round(Number(value) * 100);
}

function randomHex(byteCount: number): string {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return bytesToHex(bytes);
}

function xorPayErrorMessage(status: string | undefined): string {
  switch (status) {
  case "missing_argument": return "XorPay 参数缺失，请检查服务端配置";
  case "aid_not_exist": return "XorPay AID 不存在，请检查账号配置";
  case "pay_type_error": return "XorPay 支付类型错误";
  case "sign_error": return "XorPay 签名错误，请检查 app secret";
  case "order_payed": return "订单已支付";
  case "order_expire": return "订单已过期，请重新下单";
  case "fee_error": return "XorPay 余额不足或手续费扣除失败";
  case "app_off": return "XorPay 账号被冻结或未启用";
  case "no_contract":
  case "no_alipay_contract": return "XorPay 支付渠道尚未签约";
  default: return "创建 XorPay 支付订单失败";
  }
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

function isRefundRevocationEvent(event: PaddleEvent): boolean {
  if (event.event_type !== "adjustment.created" && event.event_type !== "adjustment.updated") return false;
  const data = event.data ?? {};
  const action = stringValue(data.action)?.toLowerCase();
  const status = stringValue(data.status)?.toLowerCase();
  return (action === "refund" || action === "chargeback") && status === "approved";
}

function adjustmentRevocationReason(data: JsonObject): string {
  const action = stringValue(data.action) ?? "adjustment";
  const status = stringValue(data.status) ?? "approved";
  return `${action}:${status}`;
}

function paddleTransactionIDFromEvent(event: PaddleEvent): string | null {
  if (event.event_type === "transaction.completed") return stringValue(event.data?.id);
  return findAdjustmentTransactionID(event.data ?? {});
}

function findAdjustmentTransactionID(data: JsonObject): string | null {
  return stringValue(data.transaction_id)
    ?? stringValue(data.paddle_transaction_id)
    ?? stringValue(objectValue(data.transaction)?.id)
    ?? stringValue(objectValue(data.order)?.transaction_id);
}

function maxDevicesForLicense(license: LicenseRow, order: OrderRow, env: Env): number {
  const metadataLimit = positiveIntegerValue(license.metadata?.max_devices ?? license.metadata?.maxDevices);
  if (metadataLimit) return metadataLimit;
  return maxDevicesForOrder(order, env);
}

function maxDevicesForOrder(order: OrderRow, env: Env): number {
  const amount = order.total_amount_minor;
  const unitPrice = devicePriceMinor(env);
  if (typeof amount === "number" && amount > 0) {
    return Math.max(1, Math.floor(amount / unitPrice));
  }
  return positiveInteger(env.LICENSE_MAX_DEVICES, 2);
}

function devicePriceMinor(env: Env): number {
  return positiveInteger(env.LICENSE_DEVICE_PRICE_MINOR, 200);
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
  const data = await response.json().catch((): JsonObject => ({})) as JsonObject;
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
  const payload = await response.json() as JsonObject;
  return findEmail(objectValue(payload.data) ?? payload);
}

async function signedActivationToken(env: Env, payload: JsonObject): Promise<string> {
  const body = base64URL(utf8Bytes(JSON.stringify(payload)));
  const signature = await hmacSha256Hex(env.SERVER_TOKEN_SECRET, body);
  return `${body}.${signature}`;
}

async function activationTokenPayload(token: string, env: Env): Promise<JsonObject | null> {
  const [body, signature] = token.split(".");
  if (!body || !signature) return null;
  const expected = await hmacSha256Hex(env.SERVER_TOKEN_SECRET, body);
  if (!constantTimeEqualHex(signature, expected)) return null;

  try {
    return JSON.parse(new TextDecoder().decode(base64ToBytes(body))) as JsonObject;
  } catch {
    return null;
  }
}

async function licenseCodeHash(code: string, env: Env): Promise<string> {
  return sha256Hex(`${env.LICENSE_HASH_PEPPER ?? ""}:${normalizeLicenseCode(code)}`);
}

async function encryptLicenseCode(code: string, env: Env): Promise<{ ciphertext: string; iv: string }> {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const key = await licenseEncryptionKey(env);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: arrayBuffer(iv) }, key, arrayBuffer(utf8Bytes(code))));
  return { ciphertext: base64URL(ciphertext), iv: base64URL(iv) };
}

async function decryptLicenseCode(license: LicenseRow, env: Env): Promise<string | null> {
  if (!license.license_code_ciphertext || !license.license_code_iv) return null;
  const key = await licenseEncryptionKey(env);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: arrayBuffer(base64ToBytes(license.license_code_iv)) },
    key,
    arrayBuffer(base64ToBytes(license.license_code_ciphertext))
  );
  return new TextDecoder().decode(plaintext);
}

async function licenseEncryptionKey(env: Env): Promise<CryptoKey> {
  const secret = env.LICENSE_ENCRYPTION_KEY ?? env.LICENSE_SIGNING_KEY;
  let keyBytes = base64ToBytes(secret);
  if (keyBytes.length !== 16 && keyBytes.length !== 24 && keyBytes.length !== 32) {
    keyBytes = new Uint8Array(await crypto.subtle.digest("SHA-256", arrayBuffer(keyBytes)));
  }
  return crypto.subtle.importKey("raw", arrayBuffer(keyBytes), "AES-GCM", false, ["encrypt", "decrypt"]);
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
  return response.json() as Promise<T[]>;
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
  return (await response.json() as T[])[0];
}

async function upsertRow<T = JsonObject>(env: Env, table: string, conflictKey: string, row: JsonObject): Promise<T> {
  const response = await supabaseFetch(env, `${table}?on_conflict=${encodeURIComponent(conflictKey)}`, {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify(row)
  });
  return (await response.json() as T[])[0];
}

async function patchRows(env: Env, table: string, query: string, values: JsonObject): Promise<void> {
  await supabaseFetch(env, `${table}?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(values)
  });
}

async function deleteRows(env: Env, table: string, query: string): Promise<void> {
  await supabaseFetch(env, `${table}?${query}`, {
    method: "DELETE",
    headers: { Prefer: "return=minimal" }
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

function positiveIntegerValue(value: JsonValue | undefined): number | null {
  const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

async function sha256Hex(value: string): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", arrayBuffer(utf8Bytes(value)))));
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  return bytesToHex(new Uint8Array(await hmacSha256(utf8Bytes(secret), utf8Bytes(message))));
}

async function hmacSha256(keyBytes: Uint8Array, message: Uint8Array): Promise<ArrayBuffer> {
  const key = await crypto.subtle.importKey("raw", arrayBuffer(keyBytes), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", key, arrayBuffer(message));
}

function md5Hex(value: string): string {
  const input = utf8Bytes(value);
  const bitLength = input.length * 8;
  const paddingLength = (56 - (input.length + 1) % 64 + 64) % 64;
  const bytes = new Uint8Array(input.length + 1 + paddingLength + 8);
  bytes.set(input);
  bytes[input.length] = 0x80;
  for (let index = 0; index < 8; index += 1) {
    bytes[bytes.length - 8 + index] = Math.floor(bitLength / 2 ** (8 * index)) & 0xff;
  }

  let a0 = 0x67452301;
  let b0 = 0xefcdab89;
  let c0 = 0x98badcfe;
  let d0 = 0x10325476;
  const shifts = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  const constants = Array.from({ length: 64 }, (_, index) => Math.floor(Math.abs(Math.sin(index + 1)) * 2 ** 32) >>> 0);

  for (let offset = 0; offset < bytes.length; offset += 64) {
    const words = new Array<number>(16);
    for (let index = 0; index < 16; index += 1) {
      const wordOffset = offset + index * 4;
      words[index] = (bytes[wordOffset] | (bytes[wordOffset + 1] << 8) | (bytes[wordOffset + 2] << 16) | (bytes[wordOffset + 3] << 24)) >>> 0;
    }

    let a = a0;
    let b = b0;
    let c = c0;
    let d = d0;
    for (let index = 0; index < 64; index += 1) {
      let f: number;
      let g: number;
      if (index < 16) {
        f = ((b & c) | (~b & d)) >>> 0;
        g = index;
      } else if (index < 32) {
        f = ((d & b) | (~d & c)) >>> 0;
        g = (5 * index + 1) % 16;
      } else if (index < 48) {
        f = (b ^ c ^ d) >>> 0;
        g = (3 * index + 5) % 16;
      } else {
        f = (c ^ (b | ~d)) >>> 0;
        g = (7 * index) % 16;
      }
      const rotated = leftRotate((a + f + constants[index] + words[g]) >>> 0, shifts[index]);
      a = d;
      d = c;
      c = b;
      b = (b + rotated) >>> 0;
    }

    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }

  return [a0, b0, c0, d0].map(littleEndianHex).join("");
}

function leftRotate(value: number, shift: number): number {
  return ((value << shift) | (value >>> (32 - shift))) >>> 0;
}

function littleEndianHex(value: number): string {
  return [0, 8, 16, 24].map((shift) => ((value >>> shift) & 0xff).toString(16).padStart(2, "0")).join("");
}

function utf8Bytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
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
