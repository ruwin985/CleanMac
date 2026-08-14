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

如果要发布给其他用户安装，必须使用 Apple Developer ID 签名并完成 notarization，否则 macOS Gatekeeper 会提示“Apple 无法验证 CleanMac 是否包含恶意软件”。首次配置公证凭据：

```bash
xcrun notarytool store-credentials cleanmac-notary --apple-id '你的 Apple ID' --team-id '你的 Team ID' --password 'App 专用密码'
```

发布可被正常打开的 DMG：

```bash
DEVELOPMENT_TEAM='你的 Team ID' NOTARY_PROFILE=cleanmac-notary VERSION=1.0.1 BUILD_NUMBER=2 bash scripts/export-universal-dmg.sh
```

### 版本更新提示

App 启动后会检查官网静态更新清单：

- 清单地址：`https://ruwin.cn/updates/cleanmac.json`
- 官网源文件：`site/static/updates/cleanmac.json`
- 下载地址：`site/static/downloads/CleanMac.dmg`
- 更新日志：`site/content/changelog.md`

发布新版本时，替换官网 DMG 并把更新清单中的 `version` / `build` 提高到大于当前已安装版本；老版本用户下次启动 CleanMac 后会看到“立即下载 / 稍后提醒 / 查看更新说明”的提示。

## 支付、授权与反馈

CleanMac 当前包含试用、授权激活、淘宝购买入口和用户反馈入口等能力。用户从 App 或官网跳转淘宝店铺下单，联系客服获取授权码后在 App 内激活。涉及价格调整、淘宝链接、授权码生成、反馈渠道配置等内部运营步骤，统一维护在内部说明文档中，不放在公开 README 中。

## 授权服务

仓库新增 `server/`，默认用于运行 Node 授权服务：托管官网静态页、提供管理员手工生成授权码接口，并提供 App 端 `/licenses/activate`、`/licenses/verify` 联网校验接口。历史微信支付、Supabase/Cloudflare Worker 版本仍保留为可选回滚方案。

客户端会先使用内置 `CleanMacLicenseValidationKey` 本地校验 `CM-...` 授权码；本地校验通过后立即授权，并在配置了 `CleanMacLicenseServerURL` 时异步请求授权服务绑定订单码。服务端签发的授权码启动后会继续使用 token 复核；本地批量生成且未入库的内部授权码不会因服务端未收录而失效。部署步骤见 `server/README.md`。


## 配置说明

### 包标识

- Bundle Identifier：`com.zyb.CleanMac`

### 最低系统版本

- macOS 14.0

### 工程生成

项目保留了 XcodeGen 配置文件：

- `project.yml`

如果后续重新生成工程，请确保变更同时维护 `project.yml`、`Resources/CleanMac-Info.plist` 与 Xcode 工程配置的一致性。

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
