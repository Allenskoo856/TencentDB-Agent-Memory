# TencentDB Agent Memory 内网容器化部署手册

本文是 fork 版本的正式内网部署手册。目标是单台 Linux 主机或 NAS 上，以 Docker Compose 源码构建方式运行 Core、Knowledge、Panel、Proxy 四个独立服务；运行时不依赖公网 SaaS、Redis、TCVDB、COS 或云端遥测。

如果只需要记忆核心，可以只启动 `memory-core`；如果需要 Team 面板、Wiki/CodeGraph 和 Claude Code/CodeBuddy 接入，按本文部署完整四服务。

## 1. 交付拓扑和信任边界

```text
浏览器 ───────────────> memory-panel:8125 (宿主机映射，管理面)
Agent/Claude Code ────> memory-proxy:8096 (宿主机映射，数据面)
                              │
                              ├──> memory-core:8420
                              ├──> 内网 LLM endpoint
                              └──> SQLite proxy-data

memory-panel:8123 ────> memory-core:8420
                       └──> memory-knowledge:8421
memory-knowledge:8421 ──> memory-panel:8123 (任务完成回调)
memory-core:8420 ───────> SQLite core-data
memory-knowledge:8421 ──> SQLite/wiki knowledge-data
```

服务端口和持久化边界如下：

| 服务 | 容器端口 | 默认宿主机映射 | 必须持久化 | 默认是否需要外部服务 |
| --- | ---: | ---: | --- | --- |
| Core | 8420 | 127.0.0.1:8420 | `/data/tdai-memory` 全目录 | 仅内网 LLM |
| Knowledge | 8421 | 127.0.0.1:8424 | `/app/data` 全目录 | 仅内网 LLM（custom 模式） |
| Panel | 8123 | 127.0.0.1:8125 | 无业务数据库；模板含密钥但不落宿主机 | Core、Knowledge |
| Proxy | 8096 | 127.0.0.1:8096 | `/data/tdai-memory-proxy` | Core、内网 LLM |

Panel 内部端口是 8123、Knowledge 内部端口是 8421；为了兼容旧文档，默认宿主机端口分别为 8125、8424。需要在内网访问时，把 `.env` 的 `INTRANET_BIND_ADDRESS` 改为宿主机内网 IP 或 `0.0.0.0`，并用防火墙限制来源。

## 2. 前置条件

目标机需要：

- Docker Engine 和 Compose v2；建议使用 OrbStack、Docker Engine 或目标 NAS 自带的 Docker，不需要在目标机安装 Node.js。
- x86_64/amd64 或 arm64 与构建机一致。原生依赖必须在目标架构的 Linux builder 中构建。
- 至少约 4 vCPU、8 GiB 可用内存用于首次四镜像构建；运行时容量取决于 LLM 请求、Wiki 数量和代码图大小。
- 一个可从容器访问的内网 OpenAI-compatible Chat Completions endpoint。Core、Proxy、Knowledge 默认都按 OpenAI-compatible 方式调用。
- 一套稳定的备份位置。不要把 Docker volume 当作备份本身。

检查命令：

```bash
docker version
docker compose version
docker info
```

如果构建机使用内网镜像仓库，把 `APT_MIRROR` 和 `NPM_REGISTRY` 设为已批准的内部地址。它们只在 `docker compose build` 阶段使用，容器运行时不会执行 apt/npm 下载。

## 3. 获取 fork 和准备目录

```bash
git clone https://github.com/Allenskoo856/TencentDB-Agent-Memory.git
cd TencentDB-Agent-Memory
git remote -v
git checkout codex/intranet-containerization
cd deploy/intranet
cp .env.example .env
```

建议保留 upstream 以便后续同步：

```bash
git remote add upstream https://github.com/TencentCloud/TencentDB-Agent-Memory.git
git fetch upstream
```

不要把真实 `.env`、备份包、导出的 user key 或 metadata 实例配置提交到 Git。仓库已忽略 `deploy/intranet/.env`、`backups/` 和 `runtime/`。

## 4. 生成和填写密钥

Core 有两层认证，必须分开保存：

1. `TDAI_GATEWAY_API_KEY`：Core 服务层 Bearer。Proxy 调 Core、Panel 后端调 Core、bootstrap 请求都使用它。
2. `TDAI_ADMIN_USER_KEY`：Metadata system admin 的用户 key。Panel 登录和 Agent 客户端认证使用 user key；Proxy 会把客户端 Bearer user key 转交 Core `/v3/meta/auth/verify`。

生成候选值：

```bash
openssl rand -hex 32
printf 'sk-mem-%s\n' "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)"
```

编辑 `.env`，至少替换：

```dotenv
TDAI_GATEWAY_API_KEY=<第一条随机值>
TDAI_ADMIN_USER_KEY=<第二条随机值>
TDAI_LLM_BASE_URL=http://llm.internal.example/v1
TDAI_LLM_API_KEY=<内网模型服务凭据>
TDAI_LLM_MODEL=<内网模型名>
INTRANET_LLM_BASE_URL=http://llm.internal.example/v1
INTRANET_LLM_API_KEY=<Proxy 使用的内网模型服务凭据>
INTRANET_LLM_MODEL=<Proxy 使用的模型名>
TDAI_PROXY_PUBLIC_URL=http://<宿主机内网地址>:8096
KNOWLEDGE_PUBLIC_BASE_URL=http://<宿主机内网地址>:8424/v3
```

`TDAI_LLM_*`、`INTRANET_LLM_*` 和 `KNOWLEDGE_LLM_*` 可以指向同一模型服务，也可以分别指定。模型服务必须是容器能访问的 base URL，例如 `http://10.10.0.20:8000/v1`。不要把公网 URL 作为内网默认值。

## 5. 配置解析和构建

先检查 Compose 展开后的最终配置：

```bash
docker compose --env-file .env config
docker compose --env-file .env config --images
```

检查重点：

- 四个 build context 分别指向 `MemoryCore`、`MemoryKnowledge`、`MemoryPanel`、`MemoryProxy`。
- secret 值来自 `.env` 或容器环境，不出现在 tracked YAML/JSON 模板中。
- `memory-core` 的 `TDAI_GATEWAY_API_KEY` 非空。
- Panel 的 metadata 模板只在容器内渲染。
- Proxy 的 `auth.apiKey` 与 Core Bearer 相同，否则 Proxy 的 auth/verify 会得到 401。
- 本 profile 没有 Redis，所以 Proxy 的 Redis-backed TPM/QPM 限流显式关闭；不要只把 `rateLimit.tpm/qpm` 改成正数，否则应先接入内网 Redis。
- `COMPOSE_NETWORK_INTERNAL=true` 只有在 LLM 服务也能通过该 Docker 网络到达时才可用。

构建：

```bash
docker compose --env-file .env build --pull=false
```

`--pull=false` 适合已有基础镜像缓存的内网构建机；首次构建或明确刷新 Node 基础镜像时可以去掉。生产构建应固定 `node:22-slim` 的内部镜像 digest，并记录源码 commit、基础镜像 digest、架构和镜像 sha256。

## 6. 启动和首次初始化

```bash
docker compose --env-file .env up -d
docker compose --env-file .env ps
docker compose --env-file .env logs --tail=200 memory-core memory-knowledge memory-panel memory-proxy
```

服务 healthy 后执行一次 admin 初始化：

```bash
docker compose --env-file .env --profile bootstrap run --rm core-bootstrap
```

bootstrap 逻辑：

- 第一次空数据库返回 HTTP 200，使用指定的 `TDAI_ADMIN_USER_KEY` 创建 `system_admin`。
- 已初始化数据库返回 HTTP 409，脚本将其视为幂等成功，不会删除或覆盖已有 admin。
- Core Bearer 错误、user key 为空、数据库目录不可写或 Core 不健康会失败。

验证：

```bash
./scripts/verify.sh
```

该脚本检查四个 health、Core 的 Bearer + admin user key，以及 Proxy 非法 user key 必须为 401。它不调用真实 LLM；完整代理链路按 [使用手册](./USAGE_CN.md) 做受控请求。

## 7. 访问控制和反向代理

单机默认只绑定 `127.0.0.1`。给内网其他机器使用时：

```dotenv
INTRANET_BIND_ADDRESS=10.10.0.15
TDAI_PROXY_PUBLIC_URL=http://10.10.0.15:8096
KNOWLEDGE_PUBLIC_BASE_URL=http://10.10.0.15:8424/v3
```

并在宿主机防火墙只允许管理网段访问 8125、需要接入 Agent 的网段访问 8096。8420/8424 除非明确需要 API 调试，不应暴露给普通用户；Knowledge 当前 HTTP API 没有内置 Bearer middleware，更应保持内网隔离。

生产上可将 Nginx/Traefik 放在宿主机：

- `/memory/` → Panel 8125，增加 HTTPS、管理网段 ACL 和 body 限制。
- `/llm/` → Proxy 8096，保留长请求超时和 SSE。
- Core 的 `/health` 可作为内部 readiness，业务 API 不直接给浏览器。

不要把 `TDAI_GATEWAY_API_KEY`、`api_key` 或 Proxy admin key 写进 URL、前端静态文件或反向代理访问日志。

## 8. 离线/半离线交付

“运行时不出网”和“构建机完全无网”是两个不同验收项。

### 8.1 有内网镜像的构建机

在有 Linux/目标架构的构建机上：

```bash
APT_MIRROR=http://apt-mirror.internal/debian \
NPM_REGISTRY=http://npm-mirror.internal/ \
docker compose --env-file .env build
docker compose --env-file .env config --images > images.txt
```

将四个镜像保存为制品：

```bash
mkdir -p artifacts
docker compose --env-file .env config --images | sort -u | \
  xargs docker save | gzip -c > artifacts/tdai-memory-intranet-images.tar.gz
sha256sum artifacts/tdai-memory-intranet-images.tar.gz > artifacts/SHA256SUMS
```

把源码 commit、去除 secret 的 Compose 配置、镜像清单和 checksum 一起交付。目标机导入并校验：

```bash
sha256sum -c artifacts/SHA256SUMS
gunzip -c artifacts/tdai-memory-intranet-images.tar.gz | docker load
docker compose --env-file .env up -d --no-build
```

### 8.2 目标机运行期无公网出口

构建完成后，四个容器不需要 npm/apt 下载。将 `COMPOSE_NETWORK_INTERNAL=true` 作为额外门禁前，先确认内网 LLM 地址在 Docker 网络内可达；否则保持 false，并在出口防火墙只放行指定的内网 LLM 地址。

运行期 smoke：

```bash
docker image inspect tdai-memory-core:intranet tdai-memory-knowledge:intranet \
  tdai-memory-panel:intranet tdai-memory-proxy:intranet >/dev/null
docker compose --env-file .env up -d --no-build
./scripts/verify.sh
```

`verify.sh` 只依赖健康端点和 Core 本地鉴权；它不会把“容器启动”误报成“LLM 业务调用成功”。完整 LLM 业务验收必须使用内网模型端点做一次真实请求。

### 8.3 Debian 10/UOS 兼容启动门禁

仓库的 `Intranet container validation` Action 在四个镜像构建完成后会运行
`scripts/verify-debian10-uos-runtime.sh`。这个门禁包含三部分：

1. 拉起 `debian:10`（buster）控制容器，确认 Debian 10 用户态和普通运行身份可用；
2. 对四个实际业务镜像检查 Linux 平台以及 `10001:10001` 非 root 身份；
3. 以 `--network none`、临时可写数据目录和普通 UID/GID 启动 Core、Knowledge、Panel、Proxy，等待各自的 Docker healthcheck 变为 `healthy`。

本地复现：

```bash
cd deploy/intranet
docker pull debian:10
PULL_DEBIAN_IMAGE=0 ./scripts/verify-debian10-uos-runtime.sh
```

GitHub Action 会显式设置 `PULL_DEBIAN_IMAGE=1`，仅用于在构建 runner 上准备控制镜像；UOS 或完全离线目标机不要在验证脚本中拉公网镜像，应先把 `debian:10` 与四个业务镜像一并导入本地 Docker，然后保持 `PULL_DEBIAN_IMAGE=0`。

这个 Action 使用 GitHub 托管的 Linux runner，因此它验证的是 Debian 10 用户态下的容器启动边界、非 root 写入和运行期不出网行为，不能等同于真实 UOS 主机内核、UOS Docker 版本或目标 CPU 架构验收。将制品放到 UOS 后，仍需在 UOS 主机执行同一个脚本，并继续执行 `docker compose up -d --no-build`、`scripts/verify.sh` 以及一次真实内网 LLM 请求。若要把真实 UOS 接入 GitHub Action，需要另外注册带有 `self-hosted,linux,uos` 标签的 runner；当前 fork 没有 self-hosted runner。

## 9. 数据、备份和恢复

必须整体备份三个命名卷：

- Core：记忆 SQLite、metadata、JSONL、scene blocks、checkpoint、profile 和 backup。
- Knowledge：全局 `knowledge.db`、wiki 的 `index.db`/WAL/SHM、raw source 和 code graph。
- Proxy：SQLite session/injection 状态和本地存储。

先停写再备份：

```bash
docker compose --env-file .env stop memory-proxy memory-panel memory-knowledge memory-core
docker volume ls | grep tdai-memory-intranet
mkdir -p backups/$(date +%Y%m%d-%H%M%S)
```

在有 `busybox` 镜像的环境中，对每个实际 volume 执行：

```bash
docker run --rm \
  -v <project>_core-data:/data:ro \
  -v "$PWD/backups/<timestamp>":/backup \
  busybox tar czf /backup/core-data.tar.gz -C /data .
```

Knowledge 和 Proxy 使用同样方式替换 volume 名称。记录 volume 名称、源码 commit 和 checksum。恢复前停止四服务，把对应 volume 内容解包，再启动并运行 `verify.sh`。

不要把 `docker compose down -v` 当作普通停止命令；它会删除命名卷和全部本地数据。普通维护使用 `stop`，升级使用 `up -d`，只有确认数据已备份并明确要清库时才删除卷。

## 10. 升级流程

```bash
cd TencentDB-Agent-Memory
git fetch origin
git status --short
git log -1 --oneline
cd deploy/intranet
docker compose --env-file .env stop
# 先完成 volume 备份
docker compose --env-file .env build --pull=false
docker compose --env-file .env up -d
docker compose --env-file .env --profile bootstrap run --rm core-bootstrap
./scripts/verify.sh
```

升级后必须检查：

- `docker compose ps` 四服务是否 healthy。
- admin user key 是否仍能通过 Core `auth/verify`。
- Panel 是否还能打开并读取实例。
- Proxy 非法 key 是否仍然 401，合法 key 的受控 LLM 请求是否成功。
- 重启后数据和 Wiki/CodeGraph 索引是否仍存在。

不要在没有备份的情况下改 `TDAI_INSTANCE_ID`、切换 standalone/service、替换 volume 名称或切换 SQLite schema。

## 11. 故障排查

### `docker compose config` 报变量缺失

确认在 `deploy/intranet` 执行、已复制 `.env`，且没有把变量写成带空格的未引用值：

```bash
docker compose --env-file .env config >/tmp/tdai-compose.rendered.yaml
```

### Core healthy 但 bootstrap 返回 401

检查 Core 和 bootstrap 使用的 `TDAI_GATEWAY_API_KEY` 完全相同；Core API key 不是 admin user key：

```bash
docker compose logs --tail=200 memory-core core-bootstrap
```

### Panel 启动失败或 metadata config validation failed

检查 Panel 日志里的缺失变量；模板需要 `TDAI_GATEWAY_API_KEY` 和 `TDAI_PROXY_PUBLIC_URL`。容器内生成文件在 `/tmp/metadata-instances.json`，可检查它是否为合法 JSON。不要把它复制回 Git。

### Proxy 返回 401

合法请求的 `Authorization: Bearer` 必须是 Core 已注册的 user key，不是 Core gateway key。Core Bearer 由 Proxy 内部使用，Proxy 通过 `auth.apiKey` 把它带给 Core 的 `/v3/meta/auth/verify`。

### Proxy 返回 502/上游连接失败

检查 `INTRANET_LLM_BASE_URL` 是否从 Proxy 容器可达、是否为正确 API base URL、模型名是否存在。不要用 `localhost` 指向宿主机 LLM，容器内的 `localhost` 是 Proxy 自己。

### Knowledge health 通过但 Wiki ingest 失败

Knowledge 的健康检查只代表 HTTP 进程存活，不代表 LLM 或 Git 源可用。检查 `LLM_MODE=custom`、`LLM_BASE_URL`、模型能力、内网 Git DNS/凭据和 `/app/data` 写权限。Knowledge HTTP API 当前不自行验证 token，访问控制交给网络边界。

### 构建 native 依赖失败

确认构建在 Linux 目标架构进行，APT mirror 可用，且没有把 macOS `node_modules` 复制进 context。不要把 macOS native binary 打包进 Linux 镜像。

## 12. 交付验收记录模板

每次交付建议记录：

| 项目 | 结果 |
| --- | --- |
| fork URL、branch、commit |  |
| 目标架构和 Docker/Compose 版本 |  |
| 四镜像 tag、digest、SHA256 |  |
| `docker compose config` | passed / failed |
| `./scripts/verify.sh` | passed / failed |
| Core auth/verify | passed / failed |
| 合法 Proxy + 内网 LLM 请求 | passed / failed |
| Panel 登录、Team/Agent/Task | passed / failed |
| Wiki ingest / CodeGraph sync | passed / failed |
| 停机备份、重启恢复 | passed / failed |
| 目标环境无公网运行检查 | passed / skipped（说明原因） |

只有实际运行并保留日志、响应和制品 checksum，才能把对应项目记录为 passed。
