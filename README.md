# DeepSeek Harness Docker · 雨云一键部署版

[![Docker Image](https://img.shields.io/badge/docker-keke0904%2Fdeepseek--harness-2496ed?logo=docker&logoColor=white)](https://hub.docker.com/r/keke0904/deepseek-harness)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`，DeepSeek AI 官方开源的 Agent 智能体框架，**一切皆插件**）Web UI 的 Docker 镜像，开箱即用，支持**雨云云应用（RCA）一键部署**。

> 面向个人使用做了三处增强：内置密码登录、持久卷权限自愈、旧浏览器兼容——同时保持 dsh 本体非 root 运行 + Landlock 沙箱的安全基线。

---

## ✨ 特性

| 特性 | 说明 |
|---|---|
| 🔐 **内置密码登录** | 首次访问注册密码，之后需登录（默认开启，`DSH_AUTH=0` 可关闭） |
| 💾 **持久卷自愈** | 自动修复 root 属主卷（K8s/雨云不继承镜像属主的问题），幂等、重启不重复 chown |
| 🌐 **免配置公网访问** | 鉴权模式下 dsh 只监听回环地址，网关自动处理 Host/Origin，无需填公网地址 |
| 🧩 **旧浏览器兼容** | 注入 `crypto.randomUUID` polyfill（微信内置浏览器等旧 WebView 也能用） |
| 🔒 **非 root + 沙箱** | 降权 uid 1000 运行，bash 工具走 Landlock 沙箱（full），绝不无沙箱执行 |
| 🚀 **多阶段构建** | 基于 npm 官方包 `@deepseek-ai/dsh`，原生依赖构建期编译，运行镜像精简 |

---

## 🚀 快速开始

```sh
docker run -d --name dsh \
  -p 3080:3080 \
  -v dsh-data:/data \
  keke0904/deepseek-harness:0.1.0-rc.6-4
```

打开 http://localhost:3080 ：

1. **首次访问** → 自动跳转「设置密码」页，设置至少 8 位密码；
2. 之后每次访问需登录（会话 30 天有效）；
3. 进入后在「设置 → 模型」填入 DeepSeek API Key（或通过环境变量 `DEEPSEEK_API_KEY` 注入），选择工作区即可开始使用。

> 忘记密码？删除持久卷中的 `/data/auth/password.json` 后重启，即可重新设置。

### docker compose

```yaml
services:
  dsh:
    image: keke0904/deepseek-harness:0.1.0-rc.6-4
    container_name: dsh
    restart: unless-stopped
    ports:
      - "3080:3080"
    volumes:
      - dsh-data:/data
      # 可选：agent 工作区
      # - ./workspace:/workspace
    environment:
      - DSH_HOME=/data
      - PORT=3080
      - DSH_TELEMETRY_DISABLED=1
      # 可选：模型密钥（也可在 Web UI 配置）
      # - DEEPSEEK_API_KEY=sk-...
volumes:
  dsh-data:
```

---

## 📦 镜像

Docker Hub（公开）：[keke0904/deepseek-harness](https://hub.docker.com/r/keke0904/deepseek-harness)

| Tag | 说明 |
|---|---|
| `0.1.0-rc.6-4` | **当前推荐**：含密码登录 + 全部修复 |
| `latest` | 跟随最新构建 |
| `0.1.0-rc.6-3` / `-2` / `-1` | 历史迭代（雨云按 tag 缓存，升级请换新 tag） |

---

## ⚙️ 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `3080` | 公网监听端口（鉴权网关）；改端口需同时删除 `$DSH_HOME/profiles/web/cordis.patch.yml` 后重启（该文件首启写入并固定内部端口） |
| `DSH_HOME` | `/data` | 数据目录，**务必挂卷**（设置、密钥、会话、profiles、密码都在这里） |
| `DSH_AUTH` | `1` | 密码登录开关：`1`=开启（默认），`0`=关闭（回到无鉴权模式） |
| `DSH_TELEMETRY_DISABLED` | `1` | 关闭遥测 |
| `DEEPSEEK_API_KEY` | 空 | 可选，模型密钥（也可在 Web UI 配置） |
| `DSH_RUNTIME_UID` / `DSH_RUNTIME_GID` | `1000` | 覆盖运行用户（需与卷属主匹配，一般不用改） |
| `DSH_TRUSTED_HOSTS` | 空 | 仅 `DSH_AUTH=0` 时使用：空格分隔的裸 `host[:port]`（如 `38.246.252.220:9990`），会自动清洗 `http://`/路径/斜杠 |
| `DSH_TRUST_FENCE` | 空 | 仅 `DSH_AUTH=0` 时使用：设 `0` 关闭 /api 信任围栏（免配置直连）；默认开启需配 `DSH_TRUSTED_HOSTS` |

> 鉴权模式（默认）下 `DSH_TRUSTED_HOSTS` 与 `DSH_TRUST_FENCE` 都不需要。

---

## ☁️ 雨云云应用（RCA）部署

**逐字段填写文档**：[RCA-TEMPLATE.zh.md](RCA-TEMPLATE.zh.md)（对照雨云官方教程 [topic/11296](https://forum.rainyun.com/t/topic/11296)）

核心配置速览：

| 项 | 值 |
|---|---|
| 镜像 | `keke0904/deepseek-harness:0.1.0-rc.6-4` |
| 最小资源 | 1 核 / 512MB（推荐 1核1GB+） |
| Env | `DSH_HOME=/data`、`PORT=3080`、`DSH_TELEMETRY_DISABLED=1` |
| 持久卷 | 挂载路径 `/data`（与 DSH_HOME 一致），子路径 `dsh`，目录类型 |
| 服务 | 外部访问，内部端口 `3080`，协议 tcp |

### 一键部署按钮

```markdown
[![通过雨云一键部署](https://rainyun-apps.cn-nb1.rains3.com/materials/deploy-on-rainyun-cn.svg)](https://app.rainyun.com/apps/rca/store/<应用ID>?ref=<你的UID>)
```

英文版素材：`https://rainyun-apps.cn-nb1.rains3.com/materials/deploy-on-rainyun-en.svg`
推广链接格式：`https://app.rainyun.com/apps/rca/store/<应用ID>?ref=[UID]` 或 `.../<应用ID>/[优惠码]_`
上架与返利流程见雨云官方指南 [topic/11430](https://forum.rainyun.com/t/topic/11430)。

---

## 🔨 本地构建 / 测试 / 发布

```sh
# 构建（默认 npm 包 0.1.0-rc.6；换版本：--build-arg DSH_VERSION=<version>）
docker build -t deepseek-harness:0.1.0-rc.6 .

# 冒烟测试（8 项：绑定/信任围栏/沙箱/持久化/健康检查等，全过才退出 0）
./smoke-test.sh deepseek-harness:0.1.0-rc.6

# 推送新 tag 到 Docker Hub
DOCKERHUB_USERNAME=<用户> DOCKERHUB_TOKEN=<访问令牌> DSH_VERSION=0.1.0-rc.6 ./push.sh
```

- 访问令牌在 https://hub.docker.com/settings/security 创建（Read/Write/Delete）。
- **CI 自动发布（可选）**：`.github/workflows/docker-publish.yml` 配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` 两个 Secrets 后，打 `v*` tag 或手动触发即自动构建 → 冒烟 → 推送 Docker Hub + ghcr.io。

---

## ❓ 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| 日志报 `mkdir: cannot create directory '/data/profiles': Permission denied` | 旧镜像的已知问题；升级到 `0.1.0-rc.6-4` 即自动修复（记得**换新 tag**，雨云按 tag 缓存镜像） |
| 报 `trustedHosts entry "http://..." is not a bare host` | 鉴权模式无需此变量；若关闭鉴权，`DSH_TRUSTED_HOSTS` 只填裸 `host[:port]`（新版本会自动清洗 URL 格式） |
| 页面报 `crypto.randomUUID is not a function` | 旧浏览器/微信内置浏览器；用新版镜像（已内置 polyfill），或换 Chrome/Edge/Firefox/Safari 新版 |
| agent 无法执行命令，报 `SANDBOX_UNAVAILABLE` | 宿主内核不支持 Landlock（5.13+）；确认容器安全上下文是否放行 |
| 登录失败 10 次被锁 | 防爆破机制，5 分钟后自动解锁 |

---

## 📁 目录结构

```
├── Dockerfile                  # 多阶段构建（node:22-trixie-slim + npm 官方包）
├── docker-entrypoint.sh        # 入口：卷属主自愈 → profile 补丁 → 降权启动
├── auth-proxy.js               # 内置密码登录网关（零依赖，首次注册+登录+会话）
├── polyfill-randomuuid.mjs     # 构建期注入 crypto.randomUUID 兼容垫片
├── patch-trust-fence.mjs       # 构建期补丁：DSH_TRUST_FENCE 免配置直连开关
├── smoke-test.sh               # 一键冒烟测试
├── push.sh                     # 一键发布脚本
├── docker-compose.yml          # 本地一键起服务
├── RCA-TEMPLATE.zh.md          # 雨云模板逐字段填写文档
└── .github/workflows/          # CI 自动构建发布
```

## 📄 许可证

MIT。上游项目 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 同样为 MIT 许可，其第三方依赖许可见上游仓库的 [THIRD_PARTY_NOTICES](https://github.com/deepseek-ai/deepseek-harness/blob/master/THIRD_PARTY_NOTICES.md)。
