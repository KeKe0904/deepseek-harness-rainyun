# deepseek-harness-docker

将 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）Web UI 打包为 Docker 镜像的仓库。

- 基于 npm 官方包 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)（自带构建好的前端，无需源码编译）
- 多阶段构建：原生依赖（node-pty/koffi）在构建阶段编译，运行镜像保持精简
- 内置入口脚本解决两个官方限制：`--host 0.0.0.0` 被 CLI 拒绝 → 通过 profile 补丁层覆盖为 0.0.0.0；`/api` 浏览器信任围栏 → 通过 `DSH_TRUSTED_HOSTS` 声明公网访问地址

## 构建

```sh
docker build -t deepseek-harness:0.1.0-rc.6 .
# 指定其他 npm 版本：--build-arg DSH_VERSION=0.1.0-rc.5
```

## 冒烟测试（一键复验）

```sh
./smoke-test.sh                 # 默认 deepseek-harness:0.1.0-rc.6
./smoke-test.sh <image-tag>     # 指定镜像
```

覆盖：入口脚本/profile 初始化、0.0.0.0 绑定、HTTP + `__DSH_BOOT__`、/api 信任围栏、沙箱（Landlock 探测 + 真实受限 bash 执行）、重启持久化、健康检查。全部 PASS 才退出 0。

## 已发布的镜像

镜像已推送到 Docker Hub（公开）：

- `keke0904/deepseek-harness:0.1.0-rc.6`
- `keke0904/deepseek-harness:latest`

雨云 RCA 模板「镜像」字段填：`keke0904/deepseek-harness:0.1.0-rc.6`。

发布新版（换版本号后）：`DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=... ./push.sh`。

## 推送到 Docker Hub（发布新版用）

```sh
# 方式一：本地脚本（推荐，自动打 rc 和 latest 两个 tag）
DOCKERHUB_USERNAME=<用户> DOCKERHUB_TOKEN=<访问令牌> ./push.sh

# 方式二：手动
docker tag deepseek-harness:0.1.0-rc.6 <你的用户名>/deepseek-harness:0.1.0-rc.6
docker tag deepseek-harness:0.1.0-rc.6 <你的用户名>/deepseek-harness:latest
docker login
docker push <你的用户名>/deepseek-harness:0.1.0-rc.6
docker push <你的用户名>/deepseek-harness:latest
```

访问令牌在 https://hub.docker.com/settings/security 创建（Read/Write/Delete 权限）。

## CI 自动发布（可选）

`docker/.github/workflows/docker-publish.yml` 提供了 GitHub Actions 工作流：仓库结构保持本目录布局（`docker/` 子目录 + `.github/workflows/`），配好 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` 两个 Secrets 后，打 `v0.1.0-rc.6` 这样的 tag（或手动触发）即自动构建、冒烟测试、推送到 Docker Hub 和 ghcr.io。

## 运行

```sh
docker run -d --name dsh \
  -p 3080:3080 \
  -v dsh-data:/data \
  -e DSH_TRUSTED_HOSTS=localhost \
  deepseek-harness:0.1.0-rc.6
```

打开 http://localhost:3080 ，在「设置 → 模型」填入 DeepSeek API Key（或通过环境变量 `DEEPSEEK_API_KEY` 注入）。

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `3080` | 监听端口。注意：首次启动时会写入 `$DSH_HOME/profiles/web/cordis.patch.yml`（webserver 行），之后改 `PORT` 环境变量不生效；需删除该文件（或编辑其中的 port 值）后重启 |
| `DSH_HOME` | `/data` | 数据目录（务必挂卷） |
| `DSH_TRUSTED_HOSTS` | 空 | 空格分隔的 `host[:port]`，/api 信任围栏接受的外部访问地址 |
| `DSH_TELEMETRY_DISABLED` | `1` | 关闭遥测 |
| `DEEPSEEK_API_KEY` | 空 | 可选，模型密钥（也可在 Web UI 配置） |

### 数据持久化

所有用户数据（settings.yaml、.credentials.yaml、会话、profiles、storages）都在 `$DSH_HOME`，挂载命名卷 `/data` 即可持久化。agent 工作区为 `/workspace`，可另挂卷。

### 运行用户（安全加固）

容器以 root 启动入口脚本，**自动修复持久卷属主后降权为 `node`（uid 1000）运行 dsh**——harness 本身永不 root 运行，Landlock 沙箱保持 full。这解决了雨云/K8s 持久卷**不继承镜像属主**（卷根是 root，导致 `mkdir /data/profiles` 报 Permission denied）的问题：首次启动会自动 `chown` 卷数据到 uid 1000（幂等，仅需要时执行）。bind mount 场景建议仍用命名卷。特殊情况下可用 `DSH_RUNTIME_UID`/`DSH_RUNTIME_GID` 覆盖运行用户（需与卷属主匹配）。

### 进程沙箱说明

dsh 的 bash 工具在 Linux 上按序探测 **bubblewrap** → **Landlock**（内核 5.13+），两者都不可用时**拒绝执行**（`SANDBOX_UNAVAILABLE`），绝不无沙箱运行。本镜像已安装 bubblewrap；在 Docker/K8s 中若宿主内核或安全配置不允许，可临时用以下方式验证：

```sh
# 容器内验证 bwrap
docker exec dsh bwrap --ro-bind / / -- true && echo "bwrap OK"
# 容器内验证 Landlock（结果 full/partial/unusable）
docker exec dsh node -e "import('@deepseek-ai/node-addon-landlock-run').then(m=>console.log(m.probe(m.launcherPath())))"
```

## 雨云云应用（RCA）上架

逐字段填写文档见 [RCA-TEMPLATE.zh.md](RCA-TEMPLATE.zh.md)（对照雨云官方教程 topic/11296）。
上架与推广流程（推广链接、返利、合作标识）见雨云官方指南 topic/11430。

### 雨云一键部署按钮

```markdown
[![通过雨云一键部署](https://rainyun-apps.cn-nb1.rains3.com/materials/deploy-on-rainyun-cn.svg)](https://app.rainyun.com/apps/rca/store/<应用ID>?ref=<你的UID>)
```

英文版：`https://rainyun-apps.cn-nb1.rains3.com/materials/deploy-on-rainyun-en.svg`，
链接格式 `https://app.rainyun.com/apps/rca/store/<应用ID>/<优惠码>_`。
