import crypto from "node:crypto";

const endpoint = process.env.CLEANMAC_LICENSE_WEBHOOK_URL
  ?? "https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license/webhooks/paddle";
const webhookSecret = process.env.PADDLE_WEBHOOK_SECRET;
const testEmail = process.env.TEST_EMAIL;
const priceId = process.env.PADDLE_PRICE_ID ?? "pri_01kz09hjt717rwqqr4nj82dy81";

if (!webhookSecret) {
  console.error("Missing PADDLE_WEBHOOK_SECRET environment variable.");
  process.exit(1);
}

if (!testEmail) {
  console.error("Missing TEST_EMAIL environment variable.");
  process.exit(1);
}

const now = Date.now();
const body = JSON.stringify({
  event_id: `evt_test_${now}`,
  event_type: "transaction.completed",
  occurred_at: new Date().toISOString(),
  data: {
    id: `txn_test_${now}`,
    status: "completed",
    customer_id: "ctm_test_cleanmac",
    customer: { email: testEmail },
    currency_code: "USD",
    details: {
      totals: { total: "1000" },
      line_items: [
        {
          price: {
            id: priceId,
            product_id: "pro_test_cleanmac"
          }
        }
      ]
    }
  }
});

const timestamp = Math.floor(Date.now() / 1000).toString();
const signature = crypto
  .createHmac("sha256", webhookSecret)
  .update(`${timestamp}:${body}`)
  .digest("hex");

const response = await fetch(endpoint, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Paddle-Signature": `ts=${timestamp};h1=${signature}`
  },
  body
});

const text = await response.text();
console.log(`POST ${endpoint}`);
console.log(`Status: ${response.status}`);
console.log(text);

if (!response.ok) process.exit(1);
