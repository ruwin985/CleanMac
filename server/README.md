# CleanMac License Server

当前默认架构已改为“淘宝下单 + 客服发授权码 + 服务端校验授权码”：

- 官网和 App 的购买按钮直接跳转淘宝店铺/商品页。
- 用户在淘宝下单后联系客服。
- 你在服务器上调用管理接口生成 `CM-...` 授权码，发给用户。
- 用户在 CleanMac 内输入授权码后，App 请求 `/licenses/activate` 绑定设备。
- App 后续启动会请求 `/licenses/verify` 复核授权状态。

历史微信支付 Native 扫码实现保留在 `src/wechatpay-local-server.ts`，但当前默认 `npm run dev/start` 不再使用微信支付流程。

## 默认服务端点

默认监听 `0.0.0.0:1314`：

- `GET /health`：健康检查
- `POST /admin/licenses`：管理员生成手工授权码
- `POST /licenses/activate`：App 输入授权码后绑定当前设备
- `POST /licenses/verify`：App 启动后复核已激活设备是否仍有效
- `GET /*`：托管 `site/public` 官网静态页面

## 环境变量

复制示例文件：

```bash
cd server
cp .dev.vars.example .dev.vars
```

填写：

```bash
PORT="1314"
SITE_DIR="../site/public"
DATA_DIR="./data"
PURCHASE_URL="https://你的淘宝店铺或商品链接"

LICENSE_SIGNING_KEY="SAME_BASE64_KEY_AS_CLEANMAC_LICENSE_VALIDATION_KEY"
LICENSE_ENCRYPTION_KEY="RANDOM_32_BYTE_BASE64_SECRET_FOR_ENCRYPTING_LICENSE_CODES"
LICENSE_HASH_PEPPER="RANDOM_LONG_SECRET_FOR_DB_HASHING"
SERVER_TOKEN_SECRET="RANDOM_LONG_SECRET_FOR_ACTIVATION_TOKENS"
ADMIN_TOKEN="RANDOM_LONG_SECRET_FOR_MANUAL_LICENSE_API"
MOBILE_ISSUE_TOKEN="RANDOM_LONG_SECRET_FOR_PHONE_ISSUE_PAGE"
LICENSE_MAX_DEVICES="1"

APP_NAME="CleanMac"
SUPPORT_EMAIL="ruwin_211@126.com"
CLEANMAC_DOWNLOAD_URL="https://ruwin.cn/downloads/CleanMac.dmg"
```

生成随机密钥：

```bash
openssl rand -base64 32
```

说明：

- `LICENSE_SIGNING_KEY` 必须和 App 内 `CleanMacLicenseValidationKey` 一致，否则授权码无法通过 App 本地校验。
- `ADMIN_TOKEN` 只给你自己调用 `/admin/licenses` 用，不要泄露。
- `LICENSE_MAX_DEVICES='1'` 表示一个授权码只能绑定 1 台设备。
- `.dev.vars` 和 `data/license-store.json` 都包含敏感信息，不要提交到 git。

## 构建官网

本地 Node 服务会直接托管 `site/public`：

```bash
cd site
hugo --cleanDestinationDir --minify
```

## 启动服务

```bash
cd server
npm install
npm run build
npm run start
```

开发时可用：

```bash
npm run dev
```

健康检查：

```bash
curl -fsS http://127.0.0.1:1314/health
```

## 淘宝客服发码助手

### 手机千牛发码

在手机浏览器打开发码助手链接：

```text
http://服务器IP/admin/taobao-reply?token=MOBILE_ISSUE_TOKEN
```

从手机千牛复制淘宝订单号，粘贴到页面里，点击「生成回复模板」，再点击「复制回复内容」回到千牛粘贴发送。

也可以直接把订单号带进链接：

```text
http://服务器IP/admin/taobao-reply?token=MOBILE_ISSUE_TOKEN&order=淘宝订单号
```

`MOBILE_ISSUE_TOKEN` 可以生成授权码，不要发给客户。生产环境建议配置 HTTPS 后再长期使用。

### 服务器命令发码

在淘宝订单确认后，在服务器上执行：

```bash
cd /www/wwwroot/CleanMac/server
npm run issue:taobao -- --order 淘宝订单号
```

命令会输出授权码和可直接复制到千牛/淘宝客服窗口的回复模板。同一个淘宝订单号重复执行时，会返回原授权码，不会重复新建。

本地开发时可先启动授权服务：

```bash
npm run dev:license
```

也可以直接调用管理接口：

```bash
curl -X POST http://127.0.0.1:1314/admin/licenses \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "count": 1,
    "taobaoOrderId": "淘宝订单号"
  }'
```

返回里的 `licenseCode` 就是发给用户的授权码，例如：

```text
CM-XXXXXXX-XXXXXXX-XXXXXXX
```

如果你不想把管理接口暴露到公网，建议只在服务器本机调用 `http://127.0.0.1:1314/admin/licenses`。Nginx 可额外禁止外网访问 `/admin/`。

## 阿里云部署建议

当前阿里云轻量应用服务器可用 Node.js 镜像，但镜像内 Node 14 太旧，建议升级到 Node 20 或 22。

部署路径建议：

```text
/www/wwwroot/CleanMac
```

Nginx 或宝塔反向代理：

```text
https://ruwin.cn -> http://127.0.0.1:1314
```

只开放公网 `80`、`443`，不要开放 `1314`。如果使用宝塔，请限制宝塔面板端口只允许你自己的 IP 访问。

## App 接入

App 配置：

```text
CleanMacPurchaseURL=https://你的淘宝店铺或商品链接
CleanMacLicenseServerURL=https://ruwin.cn
```

客户端逻辑：

1. 用户点击购买，跳转淘宝店铺/商品页。
2. 用户下单后联系客服获取授权码。
3. 用户在 App 中输入授权码。
4. App 先本地校验 `CM-...` 授权码格式与签名。
5. App 请求 `/licenses/activate`，服务端校验授权码是否已入库并绑定设备。
6. App 启动后对已绑定 token 请求 `/licenses/verify` 复核授权状态。

## 历史微信支付方案

`src/wechatpay-local-server.ts` 保留微信支付 Native 扫码实现。后续如果重新启用微信支付，需要恢复微信支付相关环境变量，并把启动命令改回：

```bash
npm run dev:wechatpay
npm run build:wechatpay
npm run start:wechatpay
```
