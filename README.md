# CleanMac

CleanMac 是一个使用 SwiftUI 构建的 macOS 磁盘清理与空间巡检工具，面向本地磁盘空间分析、可清理内容识别、常见隐私/残留风险提示，以及基础性能优化操作。

## 功能概览

- 磁盘扫描：按分类统计用户文件、应用、系统文件、开发缓存、隐藏占用等内容
- 安全清理：识别可安全清理的缓存、日志、废纸篓和部分开发产物
- 手动清理建议：对不适合一键删除的目录提供明确提示，避免误删
- 权限引导：检测并引导用户开启“完全磁盘访问”，以便扫描受保护目录
- 风险提示：按木马病毒、广告软件、隐私追踪项等维度展示可疑残留线索
- 性能优化：提供维护脚本、DNS 缓存刷新、内存压力释放、开发缓存清理等操作

## 技术栈

- Swift 6 / SwiftPM
- SwiftUI
- Xcode 工程 + XcodeGen 配置
- 目标平台：macOS 14+

## 工程结构

```text
CleanMac/
├── CleanMac.xcodeproj/              # Xcode 工程
├── Package.swift                    # Swift Package 定义
├── project.yml                      # XcodeGen 工程配置
├── Resources/                       # 资源文件与 AppIcon
├── Sources/
│   ├── CleanMacApp.swift            # App 入口
│   ├── Models/                      # 数据模型
│   ├── Services/                    # 扫描、授权、优化等服务
│   ├── ViewModels/                  # 页面状态与业务编排
│   └── Views/                       # SwiftUI 界面
├── scripts/
│   └── export-universal-dmg.sh      # 导出通用 DMG 脚本
└── designs/                         # 图标与设计草稿
```

## 核心模块

### App 入口

- `Sources/CleanMacApp.swift`
- 创建主窗口并注入 `StorageDashboardViewModel`

### 视图层

- `Sources/Views/StorageDashboardView.swift`
- 提供主仪表盘、分类列表、清理/保护/优化相关交互界面

### 视图模型

- `Sources/ViewModels/StorageDashboardViewModel.swift`
- 负责扫描流程、状态切换、权限提示、清理动作和优化编排

### 扫描服务

- `Sources/Services/StorageScanner.swift`
- 负责磁盘分类扫描、可清理项发现、大小统计和清理执行
- 内置对下载目录旧安装包/压缩包、开发缓存、日志、废纸篓等内容的识别逻辑

### 权限服务

- `Sources/Services/DiskAuthorizationManager.swift`
- 检测“完全磁盘访问”状态
- 支持直接跳转到系统设置对应页面

### 优化服务

- `Sources/Services/SpeedOptimizer.swift`
- 封装若干系统维护动作
- 支持基于当前扫描快照执行清理型优化任务

## 当前行为说明

### 扫描范围

当前工程会重点扫描以下几类内容：

- 用户文件：桌面、文稿、下载、图片、影片、音乐
- 应用：系统应用与用户应用目录
- 系统与缓存：日志、缓存、部分系统占用
- 开发者目录：如 Xcode DerivedData、Archives、模拟器缓存等
- 隐藏占用：废纸篓、部分隐藏目录与可回收残留

### 清理策略

- 对安全前缀路径下的内容支持一键清理
- 对可能仍被系统或其他 App 使用的目录，默认给出手动清理建议
- 对权限不足的目录，返回明确错误并引导开启“完全磁盘访问”

### 权限模型

项目当前未启用 App Sandbox：

- `project.yml` 中设置了 `ENABLE_APP_SANDBOX: NO`
- 为了扫描和处理部分受保护目录，建议在本地运行时为应用授予“完全磁盘访问”

## 开发与运行

### 使用 Xcode

1. 打开 `CleanMac.xcodeproj`
2. 选择 `CleanMac` scheme
3. 直接运行即可

### 使用命令行构建

```bash
xcodebuild -project CleanMac.xcodeproj -scheme CleanMac -configuration Debug -destination 'generic/platform=macOS' build
```

### 导出通用 DMG

```bash
bash scripts/export-universal-dmg.sh
```

## 支付与授权

当前工程已接入“1 天试用 + ¥0.01 一次性买断”的授权门禁：首次启动会自动开始 1 天试用；试用结束后再次启动或重新激活主窗口时，会显示全屏蒙层，要求用户输入授权码或前往 Paddle 购买。

### Paddle 配置

1. 在 Paddle 创建 `CleanMac` 产品，并配置一次性价格 `CNY 0.01`
2. 为该价格创建或复制 Paddle Checkout 购买链接
3. 将购买链接填入 `project.yml` 的 `INFOPLIST_KEY_CleanMacPaddleCheckoutURL`
4. 生成授权密钥，并将公钥填入 `project.yml` 的 `INFOPLIST_KEY_CleanMacLicensePublicKey`
5. 重新生成 Xcode 工程或同步 Info.plist 配置后打包发布

当前 Paddle 目录项：

- Product ID：`pro_01kz09hhw9m21dgfbj2tdvs1f3`
- Price ID：`pri_01kz09hjt717rwqqr4nj82dy81`
- 当前价格：`CNY 0.01`
- App 购买入口：`https://ruwin985.github.io/CleanMac/?checkout=cleanmac#buy`

站点使用 Paddle.js overlay Checkout。需要在 Paddle Dashboard → Developer Tools → Authentication → Client-side tokens 创建一个前端 token，并填入 `site/config.toml` 的 `paddleClientToken`。已有 `priceID` 会传入 Checkout：

```toml
paddleEnvironment = 'production'
paddlePriceID = 'pri_01kz09hjt717rwqqr4nj82dy81'
paddleClientToken = 'live_...'
```

生产环境 Checkout 不能在 `localhost` 上完整测试。上线前还需要在 Paddle Dashboard 中完成两项配置：

1. Checkout → Checkout settings：将默认付款链接设置为 `https://ruwin985.github.io/CleanMac/`
2. Checkout → Website approval：提交并通过 `ruwin985.github.io` 域名审批

本地调试 Paddle Checkout 请切换到 sandbox 的 `priceID` 和 client-side token。

### Paddle 沙盒支付测试

本地不能用 production/live Checkout 完成支付测试。线下支付流程请使用 Paddle sandbox：

1. 登录 Paddle Sandbox Dashboard：`https://sandbox-vendors.paddle.com/`
2. 创建 sandbox API key，至少勾选 `product.write`、`price.write`、`client_token.write`
3. 复制 `.paddle.sandbox.env.example` 为 `.paddle.sandbox.env`，填入 sandbox API key
4. 运行脚本自动创建 sandbox 产品、一次性价格和 client-side token：

```bash
python3 scripts/setup-paddle-sandbox.py
```

脚本会生成本地覆盖配置 `site/config.local.toml`。然后用 sandbox 配置启动站点：

```bash
cd site
hugo server --config config.toml,config.local.toml
```

打开本地购买页：

```text
http://localhost:1313/CleanMac/?checkout=cleanmac#buy
```

如果你已经在 Paddle sandbox 手动创建了 price 和 client-side token，也可以直接在 `.paddle.sandbox.env` 里填：

```bash
PADDLE_SANDBOX_PRICE_ID=pri_...
PADDLE_SANDBOX_CLIENT_TOKEN=test_...
PADDLE_SANDBOX_AMOUNT_MINOR_UNITS=1
```

再运行 `python3 scripts/setup-paddle-sandbox.py` 生成本地覆盖配置。

SwiftPM/命令行调试时也可以通过环境变量覆盖：

```bash
export CLEANMAC_PADDLE_CHECKOUT_URL='https://your-paddle-checkout-url'
export CLEANMAC_LICENSE_PUBLIC_KEY='base64-public-key'
```

## 用户反馈

当前反馈窗口保留邮件反馈，同时新增了腾讯问卷入口，适合国内用户优先提交反馈。

### 腾讯问卷配置

1. 在腾讯问卷创建 CleanMac 反馈表单，并复制公开填写链接（通常形如 `https://wj.qq.com/s2/...`）
2. 将链接填入 `project.yml` 的 `INFOPLIST_KEY_CleanMacTencentSurveyURL`
3. 如果直接维护 Xcode 工程，也同步更新 `CleanMac.xcodeproj` 中的 `INFOPLIST_KEY_CleanMacTencentSurveyURL`
4. 重新构建后，反馈窗口中的「打开问卷」会跳转到腾讯问卷

打开问卷时，应用会通过 URL 参数自动带上当前填写内容和匿名诊断信息，便于在腾讯问卷里做字段预填或后台筛选：

- `source`：固定为 `cleanmac_mac_app`
- `channel`：固定为 `tencent_wenjuan`
- `feedback_type`、`name`、`email`、`message`：当前反馈表单内容
- `include_diagnostics`、`device_name`、`macos_version`、`app_version`、`build`、`arch`、`locale`：匿名环境信息
- `request_id`：本次打开问卷生成的一次性请求标识
- `attachment_name`：已选择附件的文件名；实际附件仍需用户在腾讯问卷页面重新上传

SwiftPM/命令行调试时也可以通过环境变量覆盖腾讯问卷链接：

```bash
export CLEANMAC_TENCENT_SURVEY_URL='https://wj.qq.com/s2/your-form-id/'
```

### 授权码生成

客户端不会内置 Paddle API 密钥；购买成功后需要由你通过 Paddle Webhook、后台服务或人工流程生成授权码并发给用户。

首次生成密钥对：

```bash
swift scripts/generate-license-code.swift --new-key
```

妥善保存输出的 `CLEANMAC_LICENSE_PRIVATE_KEY`，只把 `CleanMacLicensePublicKey` 配置进客户端。为 Paddle 交易生成授权码：

```bash
export CLEANMAC_LICENSE_PRIVATE_KEY='base64-private-key'
swift scripts/generate-license-code.swift --transaction txn_123 --email buyer@example.com
```

生成的 `CM1-...` 授权码可直接粘贴到过期蒙层中激活。

## 配置说明

### 包标识

- Bundle Identifier：`com.zyb.CleanMac`

### 最低系统版本

- macOS 14.0

### 工程生成

项目保留了 XcodeGen 配置文件：

- `project.yml`

如果后续重新生成工程，请确保变更同时维护 `project.yml` 与 Xcode 工程配置的一致性。
导出包执行cd ~/DiskSense && ./scripts/export-universal-dmg.sh后导出的dmg文件

## 已知事项

- 仓库中的 `build/` 目录可能包含历史构建产物；它们不代表当前源码命名状态
- 运行环境若未授予“完全磁盘访问”，部分扫描结果会受限
- 当前仓库未包含自动化测试目标

## 适用场景

- 本地磁盘空间排查
- 开发环境缓存清理
- 下载目录旧安装包整理
- 常见隐私/残留文件巡检
- 轻量级系统维护辅助

## 后续可扩展方向

- 增加单元测试与 UI 测试
- 增加更多可疑项规则与白名单机制
- 增加扫描结果导出能力
- 增加多语言 README 与应用内帮助
- 清理历史 `build/` 产物并补充发布流程文档

## 网站页面（Hugo + GitHub Pages）

仓库已新增基于 Hugo 的站点目录：

- `site/`

包含内容：

- 首页落地页模板
- CleanMac 产品介绍文案
- GitHub Pages 工作流配置

快速开始：

1. 安装 Hugo Extended
2. 进入 `site/` 目录运行 `hugo server`
3. 将 `site/config.toml` 中的 `USERNAME` 替换为你的 GitHub 用户名
4. 在 GitHub 仓库 Settings → Pages 中选择 `GitHub Actions` 作为 Source
5. 推送到 `main` 分支后自动部署
