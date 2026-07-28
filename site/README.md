# CleanMac Website

这是为 `CleanMac` 准备的 Hugo 静态站点，可通过 GitHub Pages 自动部署。

## 目录

```text
site/
├── assets/                # CSS 等 Hugo 资源
├── content/               # 页面内容
├── layouts/               # 页面模板
├── static/                # 静态资源
├── .github/workflows/     # Pages 部署工作流（如仅发布 site 目录，可迁移到仓库根）
└── config.toml            # Hugo 配置
```

## 本地预览

1. 安装 Hugo Extended
2. 在 `site/` 目录运行：

```bash
hugo server
```

默认访问地址：`http://localhost:1313/CleanMac/` 或 `http://localhost:1313/`。

## 发布到 GitHub Pages

### 方案 A：仓库根工作流

GitHub 只会自动识别仓库根目录下的 `.github/workflows/*.yml`。如果你准备直接在当前仓库启用 Pages，请把：

- `site/.github/workflows/hugo-pages.yml`

复制到：

- `.github/workflows/hugo-pages.yml`

然后在 `site/config.toml` 中把以下占位值替换成你的真实信息：

- `baseURL = 'https://USERNAME.github.io/CleanMac/'`
- `githubRepo = 'https://github.com/USERNAME/CleanMac'`

### 方案 B：把 `site/` 单独作为网站仓库

如果你计划单独维护网站仓库，可直接把当前 `site/` 内容作为新仓库根目录提交，保留 `.github/workflows/hugo-pages.yml` 即可。

## 自定义建议

- 在首页补充应用截图
- 接入下载链接（DMG / Release）
- 增加 `docs/faq.md`、更新日志和隐私说明页面
