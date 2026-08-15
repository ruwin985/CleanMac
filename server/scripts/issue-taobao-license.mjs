import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const serverRoot = resolve(scriptDirectory, "..");

loadEnvFile(join(serverRoot, ".env"));
loadEnvFile(join(serverRoot, ".dev.vars"));

const options = parseOptions(process.argv.slice(2));

if (options.help) {
  printHelp();
  process.exit(0);
}

const taobaoOrderId = requiredOption(options, "order", "请传入淘宝订单号，例如：npm run issue:taobao -- --order 1234567890");
const adminToken = process.env.ADMIN_TOKEN?.trim();
if (!adminToken) fail("缺少 ADMIN_TOKEN，请先在 server/.dev.vars 或环境变量中配置。");

const port = process.env.PORT?.trim() || "1314";
const endpoint = options.url || process.env.CLEANMAC_ADMIN_LICENSE_URL || `http://127.0.0.1:${port}/admin/licenses`;
const downloadURL = options.downloadUrl || process.env.CLEANMAC_DOWNLOAD_URL || "https://ruwin.cn/downloads/CleanMac.dmg";

const response = await fetch(endpoint, {
  method: "POST",
  headers: {
    "Authorization": `Bearer ${adminToken}`,
    "Content-Type": "application/json"
  },
  body: JSON.stringify({ count: 1, taobaoOrderId })
});

const responseText = await response.text();
let responseBody;
try {
  responseBody = JSON.parse(responseText);
} catch {
  fail(`发码接口返回非 JSON 内容：${response.status} ${responseText}`);
}

if (!response.ok || !responseBody.ok) {
  fail(`发码失败：${response.status} ${responseBody.message ?? responseText}`);
}

const license = responseBody.licenses?.[0];
if (!license?.licenseCode) fail("发码接口未返回 licenseCode。");

const message = renderCustomerMessage({
  licenseCode: license.licenseCode,
  taobaoOrderId: license.taobaoOrderId ?? taobaoOrderId,
  downloadURL
});

if (options.json) {
  console.log(JSON.stringify({
    ok: true,
    reused: Boolean(license.reused),
    taobaoOrderId: license.taobaoOrderId ?? taobaoOrderId,
    licenseCode: license.licenseCode,
    message
  }, null, 2));
} else {
  console.log("CleanMac 淘宝发码助手");
  console.log(`淘宝订单号：${license.taobaoOrderId ?? taobaoOrderId}`);
  console.log(`授权码：${license.licenseCode}`);
  console.log(`状态：${license.reused ? "已存在，复用原授权码" : "新生成"}`);
  console.log("");
  console.log("--- 复制给客户 ---");
  console.log(message);
  console.log("--- 结束 ---");
}

function renderCustomerMessage(input) {
  return [
    "您好，您购买的 CleanMac 授权码已生成：",
    "",
    `授权码：${input.licenseCode}`,
    "",
    "激活方式：",
    "打开 CleanMac → 点击「输入授权码」→ 粘贴授权码完成激活。",
    "",
    "下载地址：",
    input.downloadURL,
    "",
    `淘宝订单号：${input.taobaoOrderId}`,
    "如需帮助，请直接回复本消息。"
  ].join("\n");
}

function parseOptions(argumentsList) {
  const parsed = {};
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--help" || argument === "-h") parsed.help = true;
    else if (argument === "--json") parsed.json = true;
    else if (argument === "--order" || argument === "--taobao-order-id") parsed.order = argumentsList[++index];
    else if (argument === "--url") parsed.url = argumentsList[++index];
    else if (argument === "--download-url") parsed.downloadUrl = argumentsList[++index];
    else fail(`未知参数：${argument}`);
  }
  return parsed;
}

function requiredOption(options, name, message) {
  const value = options[name]?.trim();
  if (!value) fail(message);
  return value;
}

function loadEnvFile(path) {
  if (!existsSync(path)) return;
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

function unquoteEnvValue(value) {
  const trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1).replace(/\\n/g, "\n");
  }
  return trimmed;
}

function printHelp() {
  console.log(`Usage:
  npm run issue:taobao -- --order 淘宝订单号

Options:
  --order, --taobao-order-id  淘宝订单号，必填
  --url                      发码接口地址，默认 http://127.0.0.1:$PORT/admin/licenses
  --download-url             客户消息里的下载地址
  --json                     输出 JSON
  --help                     显示帮助`);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
