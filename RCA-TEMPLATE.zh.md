# 雨云云应用（RCA）模板逐字段填写文档 — DeepSeek Harness

> 依据雨云官方教程《App版本制作教程详解》(forum.rainyun.com/t/topic/11296) 逐字段对照。
> 创建入口：https://app.rainyun.com/apps/rca/app-template/create

## 0. 前置

- [ ] 已有雨云账号并开通云应用（RCA）能力
- [ ] 镜像已推送到公网可拉取仓库（见 README 推送章节），本文档以 Docker Hub 为例
- [ ] 准备一张应用图标（可选，商店展示用）

## 1. 应用模板（App 模板）

| 字段 | 填写建议 |
|---|---|
| 名称 | `DeepSeek Harness` |
| 简介 | DeepSeek 官方开源的 AI Agent 框架（一切皆插件），此处为 Web UI 一键部署版 |
| 分类 | 开发工具 / AI |
| 图标 | 可临时用 DeepSeek 相关素材，上架审核前替换为合规图标 |

## 2. 版本（Version）— 基本信息

| 字段 | 值 | 说明 |
|---|---|---|
| 版本号 | `0.1.0-rc.6` | 与镜像 tag 保持一致 |
| 镜像 | `keke0904/deepseek-harness:0.1.0-rc.6` | 已推送到 Docker Hub（公开），也可用 `:latest`。注意：当前为 **linux/amd64** 单架构镜像，雨云 x86_64 节点可直接拉取；若雨云给 arm64 节点，需先构建多架构镜像 |
| 最小CPU | `1` 核 | Node 服务，1 核可跑 |
| 最小内存 | `512` MB | 推荐给用户写 1GB，agent 跑任务更从容 |

## 3. 版本 — Command & Env

- **Command**：留空（使用镜像内置 ENTRYPOINT，即 `docker-entrypoint.sh`）
- **Args**：留空
- 不需要覆盖，入口脚本已处理全部初始化逻辑。

## 4. 版本 — Env 环境变量

| 键 | 值 | 说明 |
|---|---|---|
| `PORT` | `3080` | 服务监听端口，与 Services 内部端口一致 |
| `DSH_HOME` | `/data` | 数据目录，与 VolumeMounts 挂载路径一致 |
| `DSH_TELEMETRY_DISABLED` | `1` | 关闭遥测 |
| `DSH_TRUSTED_HOSTS` | 来自 Options（见下） | `/api` 信任围栏需要的公网访问地址 |

## 5. 版本 — VolumeMounts 持久化卷挂载

> ⚠️ **挂载路径（容器内路径）必填，且必须与 Env 中的 `DSH_HOME` 一致（=`/data`）**。dsh 的所有用户数据（settings.yaml、.credentials.yaml、会话、profiles、storages）都存于 `$DSH_HOME`；路径不一致时数据落不到卷里，容器重建即丢失。

| 名称 | 挂载路径（容器内） | 子路径（必填） | 内容类型 | 说明 |
|---|---|---|---|---|
| `dsh-data` | `/data` | `dsh` | 目录 | **必填**。与 Env `DSH_HOME=/data` 对应；子路径是项目共享磁盘下的子目录，**固定后勿改**（改了=数据位置变了） |
| `workspace` | `/workspace` | `workspace` | 目录 | 可选。agent 工作区；不挂则每次重建后工作区为空 |

> 说明：雨云每个项目有共享磁盘，App 挂载的是项目磁盘中的子路径；多个 App 可共用。
> 容器以非 root 用户（uid 1000）运行，镜像内已预先 chown 好 `/data` 与 `/workspace`，雨云自动创建的卷会继承属主，无需额外配置。

## 6. 版本 — Services 服务配置

| 字段 | 值 |
|---|---|
| 服务名称 | `web` |
| 显示名称 | Web UI |
| 服务类型 | **外部访问**（公网） |
| 内部端口 | `${PORT}`（或直接 `3080`） |
| 外部端口 | `3080`（或雨云分配的固定端口） |
| 协议 | `tcp` |

## 7. 版本 — Options 选项（用户部署时填写）

| 标签 | 环境变量键 | 类型 | 默认值 | 必填 | 说明 |
|---|---|---|---|---|---|
| 模型 API Key | `DEEPSEEK_API_KEY` | 文本/密码 | 空 | 否 | 部署后也可在 Web UI「设置→模型」里填；填了则开箱即用（DeepSeek 提供方默认读取此变量） |
| 公网访问地址 | `DSH_TRUSTED_HOSTS` | 文本 | 空 | 否 | **重要**：填部署完成后浏览器地址栏里的域名或 `IP:端口`（雨云分配的公网地址）。DSH 的 `/api` 有浏览器信任围栏，非回环 Host 未声明会 403。多个用空格分隔。若部署后界面无法加载（控制台 403），回这里补填重启即可 |
| 服务端口 | `PORT` | 数字 | `3080` | 否 | 一般无需修改。注意：端口值在**首次启动**时写入 profile 补丁（`/data/profiles/web/cordis.patch.yml`），之后改此选项需删除该文件或编辑其中的 port 值再重启 |

> 提示：`DSH_TRUSTED_HOSTS` 的填写时机是"先部署拿地址、再补填重启"，如果雨云支持 `$` 环境变量引用特殊变量，可尝试用 `$DSH_TRUSTED_HOSTS` 配合文档说明。最简单做法是模板里把该项做成"部署后必看"说明。

## 8. 版本 — Scripts（可选）

- 不需要。首次初始化（写 profile 补丁、绑定 0.0.0.0）已由镜像内置入口脚本完成。
- 若想用雨云的**安装脚本**（initContainer）预置 profile，可参考：在安装镜像 `node:22-slim` 中执行
  `mkdir -p /data/profiles/web` 并写入 webserver 补丁（内容见 `docker-entrypoint.sh`）。

## 9. 特殊环境变量（如有多容器需求）

本模板单容器即可，无需使用 `${rca_svc_*}` 特殊变量。若以后扩展（如加 Postgres 存会话），数据库容器内可这样引用：
- `${rca_svc_main_db}` → 数据库内部集群地址
- `${rca_svc_main_db_ext_ip}` → 数据库公网 IP

## 10. 提交上架（对照 topic/11430）

1. 模板制作完成后，在「应用模板」选项卡点击**提交上架审核**
2. 审核通过后，在**应用商店** `https://app.rainyun.com/apps/rca/store` 找到你的应用详情页链接
3. 制作推广链接：`https://app.rainyun.com/apps/rca/store/<应用ID>?ref=[你的UID]`（或 `/[优惠码]_`）
4. 在仓库 README 放一键部署按钮（素材与 Markdown 见 README.md 的「雨云一键部署」章节）
5. 想提高返利比例/拿官方合作标识：QQ 联系雨云 952637635 洽谈（开源作者专属活动）

## 11. 部署后验收清单

- [ ] 容器日志出现 `[dsh-entrypoint] starting dsh web on 0.0.0.0:3080`
- [ ] 浏览器打开雨云分配的公网地址，首页正常加载（无 /api 403）
- [ ] 设置→模型 填入 DeepSeek API Key 保存成功
- [ ] 选择一个工作区，发一条任务（如 `Summarize this repository`）能正常执行 —— 这一步同时验证**进程沙箱**（bash 工具可用）
- [ ] 重启应用后设置/会话仍在（卷持久化生效）
