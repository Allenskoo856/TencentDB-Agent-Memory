# 内网 Compose 交付目录

这里是 TencentDB Agent Memory fork 的 canonical 内网容器化部署入口。它使用源码分别构建四个容器：

| 服务 | 容器端口 | 默认宿主机端口 | 责任 | 数据边界 |
| --- | ---: | ---: | --- | --- |
| `memory-core` | 8420 | 8420 | L0-L3 记忆、Metadata、Skill Gateway | `core-data` |
| `memory-knowledge` | 8421 | 8424 | Wiki、CodeGraph、Tools | `knowledge-data` |
| `memory-panel` | 8123 | 8125 | Team/User/Agent/Task 与资产管理 UI | 配置在启动时生成到 `/tmp` |
| `memory-proxy` | 8096 | 8096 | Claude Code / OpenAI-compatible 代理和上下文注入 | `proxy-data` |

最短启动路径：

```bash
cd deploy/intranet
cp .env.example .env
# 填写 .env 中的密钥和内网 LLM 地址
docker compose config
docker compose build
docker compose up -d
docker compose --profile bootstrap run --rm core-bootstrap
./scripts/verify.sh
```

完整资料请看：

- [内网容器化部署手册](../../docs/DEPLOYMENT_CN.md)
- [使用手册与 Agent 接入](../../docs/USAGE_CN.md)

## 设计边界

- 默认 `deployMode=standalone`，Core 使用本地 SQLite；Proxy 使用 SQLite；Knowledge 使用 SQLite + 每个知识库自己的索引库。
- 默认关闭 Redis、TCVDB、COS、MongoDB、ClickHouse、Kafka、OTel、Langfuse、Opik 和 cost-guard 私有扩展。
- Proxy 的 TPM/QPM 限流依赖 Redis，因此本 profile 明确关闭限流并禁止静默 fail-open；需要限流时应接入内网 Redis 后再启用 `rateLimit`，不要只改数字。
- 运行时只依赖内网 LLM；APT/npm mirror 只用于构建阶段。将 `COMPOSE_NETWORK_INTERNAL=true` 前，必须确认 LLM 服务也在同一 Docker 网络或可通过该网络访问。
- Core 的 `TDAI_GATEWAY_API_KEY` 是服务层 Bearer；Panel/Agent 的 `user_key` 是用户层凭据，不能混用。
- Knowledge HTTP API 当前没有独立 HTTP token middleware，生产上只应通过 Docker 内网、宿主机防火墙或反向代理 ACL 访问；不要把 8424 直接暴露给不可信网络。
- 这是单机 SQLite profile，不支持把四个服务横向扩容后继续共享本地数据。多副本需要另外设计共享存储、锁和服务模式。

## 文件说明

- `docker-compose.yml`：四服务和健康依赖。
- `.env.example`：可提交模板；真实 `.env` 被忽略。
- `config/tdai-gateway.yaml`：Core standalone/BM25 配置，不含密钥。
- `config/proxy.yaml`：Proxy 内网默认配置，不含密钥。
- `config/metadata-instances.template.json`：Panel 启动时由 entrypoint 以环境变量渲染，输出文件只写入容器 `/tmp`。
- `scripts/bootstrap-admin.sh`：幂等初始化 Core system admin；首次创建返回 200，已有数据返回 409 都视为可继续。
- `scripts/verify.sh`：四个 health、Core 双层鉴权以及 Proxy 非法 user key 边界验证。
