# CleanMac License Server

授权服务负责接收 Paddle webhook、自动生成 `CM-...` 授权码、发送授权邮件，并提供 App 端联网激活接口。

当前推荐部署到 Supabase Edge Functions，原因是 `workers.dev` 在国内网络可能打不开，而 Supabase 项目域名不需要你额外购买独立域名。

## 端点

Supabase Function 基础地址：

```text
https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license
```

- `GET /health`：健康检查
- `POST /webhooks/paddle`：Paddle webhook，处理 `transaction.completed`
- `POST /licenses/activate`：App 输入授权码后的服务端校验

完整地址示例：

```text
https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license/health
https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license/webhooks/paddle
https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license/licenses/activate
```

## 数据库

你已经在 Supabase SQL Editor 执行过：

```text
server/supabase/schema.sql
```

如果换 Supabase 项目，需要重新在 SQL Editor 执行该文件。

## Supabase 部署

先登录 Supabase CLI：

```bash
cd server
npx supabase login
```

设置 secrets：

```bash
cd server
npx supabase secrets set --project-ref jzykexxkpmbdweyzzrwc \
  LICENSE_SIGNING_KEY='填 CleanMacLicenseValidationKey 同一串 base64' \
  LICENSE_ENCRYPTION_KEY='用 openssl rand -base64 32 生成' \
  LICENSE_HASH_PEPPER='用 openssl rand -base64 32 生成' \
  SERVER_TOKEN_SECRET='用 openssl rand -base64 32 生成' \
  PADDLE_WEBHOOK_SECRET='填 Paddle Notification destination 的 secret' \
  PADDLE_API_KEY='填 Paddle API key，可选但建议' \
  RESEND_API_KEY='填 Resend API key' \
  RESEND_FROM='CleanMac <license@example.com>' \
  RESEND_REPLY_TO='ruwin_211@126.com' \
  APP_NAME='CleanMac'
```

说明：

- Supabase Edge Functions 会自动注入 `SUPABASE_URL` 和 `SUPABASE_SERVICE_ROLE_KEY`，不要用 `npx supabase secrets set` 手动设置 `SUPABASE_` 前缀变量；CLI 会跳过并报 `Env name cannot start with SUPABASE_`。
- 如果将来需要手动覆盖 Supabase 项目地址或 service role key，请改用备用变量名 `CLEANMAC_SUPABASE_URL` 和 `CLEANMAC_SUPABASE_SERVICE_ROLE_KEY`。
- `LICENSE_SIGNING_KEY` 必须和 App 内 `CleanMacLicenseValidationKey` 一致，这样服务端生成的 `CM-...` 授权码旧版 App 也能本地校验通过。
- `LICENSE_ENCRYPTION_KEY` 用于加密保存授权码明文，便于邮件发送失败后安全重试。
- `LICENSE_HASH_PEPPER` 用于数据库中的授权码哈希。
- `SERVER_TOKEN_SECRET` 用于签发服务端激活 token。
- `RESEND_FROM` 需要使用 Resend 已验证的发件域名。
- `RESEND_REPLY_TO` 是用户点击“回复”时收到邮件的地址，可以用你的常用邮箱。
- `PADDLE_API_KEY` 用于 webhook 里缺少邮箱时，通过 Paddle Customer API 查询邮箱。

部署 Function：

```bash
cd server
npx supabase functions deploy cleanmac-license --project-ref jzykexxkpmbdweyzzrwc --no-verify-jwt
```

验证：

```bash
curl -fsS https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license/health
```

正常会返回类似：

```json
{"ok":true,"service":"cleanmac-license","runtime":"supabase-edge"}
```

## 发送测试授权邮件

部署 Function 且设置 `EMAIL_DELIVERY_MODE=resend` 后，可以用本地脚本模拟一条 Paddle `transaction.completed` webhook。它会真实调用 Supabase Function、写入数据库，并通过 Resend 给 `TEST_EMAIL` 发送一封授权码邮件。

先设置真实发信模式：

```bash
cd server
npx supabase secrets set --project-ref jzykexxkpmbdweyzzrwc EMAIL_DELIVERY_MODE='resend'
```

触发一封测试邮件：

```bash
cd server
PADDLE_WEBHOOK_SECRET='填 Paddle webhook secret' \
TEST_EMAIL='填你的收件邮箱' \
npm run test:email
```

成功时终端会返回 `Status: 200`，并显示类似：

```json
{"ok":true,"licenseId":"...","email":"xx***@example.com"}
```

然后检查：

- 收件邮箱是否收到 `CleanMac 授权码`。
- Resend Dashboard 是否有发送记录。
- Supabase Table Editor 里 `cleanmac_orders` 和 `cleanmac_licenses` 是否新增测试数据。

## Paddle Webhook

在 Paddle Dashboard 创建 Notification destination：

```text
https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license/webhooks/paddle
```

订阅事件：

```text
transaction.completed
```

复制 Paddle 提供的 webhook secret，保存到 Supabase secret `PADDLE_WEBHOOK_SECRET`。

## Resend 发件

1. 在 Resend 添加并验证发件域名。
2. 创建 API key。
3. 设置 `RESEND_API_KEY` 和 `RESEND_FROM`。

购买完成后，Function 会生成兼容旧版 App 的 `CM-...` 授权码，并发送到 Paddle 订单邮箱。

## App 接入

App 已配置：

```text
CleanMacLicenseServerURL=https://jzykexxkpmbdweyzzrwc.supabase.co/functions/v1/cleanmac-license
```

当前客户端逻辑：

1. 用户输入授权码。
2. App 先用本地 HMAC 逻辑校验，兼容旧授权码。
3. 本地校验失败且配置了 `CleanMacLicenseServerURL` 时，请求 `/licenses/activate`。
4. 服务端校验通过后，App 保存服务端授权信息并放行。

## Cloudflare 可选方案

`server/src/index.ts` 仍保留 Cloudflare Worker 实现。如果后续你有独立域名并能完成国内访问优化，可以继续用 Wrangler 部署 Worker；否则优先使用 Supabase Edge Function。
