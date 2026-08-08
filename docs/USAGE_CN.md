# TencentDB Agent Memory 使用手册

本文说明内网 Compose 部署完成后，管理员、普通用户和 Agent 如何使用 Core、Panel、Knowledge、Proxy 四条链路。部署命令见 [内网容器化部署手册](./DEPLOYMENT_CN.md)。

## 1. 先理解四层记忆和四个服务

```text
Agent 请求
   │
   ▼
Proxy 认证 user_key → session 初始化 → 注入 Skill/Knowledge/L2-L3
   │                                  └── 读 Core / Knowledge
   ▼
内网 LLM
   │
   └── 回写 Core 的 L0；Core 后台按策略沉淀 L1/L2/L3

Panel 负责 Team / User / Agent / Task / Asset 的管理与审核
Knowledge 负责 Wiki / CodeGraph 的构建、检索和状态回调
```

- **L0**：原始对话和近期上下文，适合保留事实来源。
- **L1**：从会话提取的原子记忆，适合召回具体偏好、决定和约束。
- **L2**：Agent/场景级归纳。
- **L3**：Team/全局共享知识。
- **Skill**：带版本、资源和执行边界的可复用工作方法。
- **Wiki**：文档的结构化页面和链接图谱。
- **CodeGraph**：代码文件、符号、调用关系和影响路径。

内网 profile 默认 embedding provider 为 `none`，检索以 SQLite/BM25 为主；如果要启用向量检索，需要额外确认目标架构的 `sqlite-vec`、embedding endpoint、容量和备份策略，不能只改一个 YAML 开关后直接宣称已验收。

## 2. 第一次登录 Panel

部署目录中的 `.env` 保存了 `TDAI_ADMIN_USER_KEY`。打开：

```text
http://<宿主机地址>:8125/
```

在实例选择页选择“内网默认记忆实例”，输入 `TDAI_ADMIN_USER_KEY`。Panel 后端把该 key 作为 `x-tdai-user-key` 转发给 Core；Core Bearer `TDAI_GATEWAY_API_KEY` 不应输入到浏览器。

管理员适合做：

- 创建普通用户、团队、Agent、Task。
- 审核、共享和回收 Skill/Wiki/CodeGraph/Chat Memory 资产。
- 配置 Agent 的固定资产和可见性。
- 查看 Knowledge 任务状态并处理失败的源。

日常 Agent 调用建议使用普通用户 key，不要直接把 admin key 写进 Claude Code、脚本或 CI。

## 3. 创建普通用户并分离运维权限

可在 Panel 的用户管理页面创建，也可以使用 Core API。下面示例假设 `.env` 在部署目录，且 `jq` 可用：

```bash
cd deploy/intranet
set -a
. ./.env
set +a

curl -sS -X POST "http://127.0.0.1:${CORE_HOST_PORT:-8420}/v3/meta/user/create" \
  -H "Authorization: Bearer $TDAI_GATEWAY_API_KEY" \
  -H "x-tdai-service-id: ${TDAI_INSTANCE_ID:-default}" \
  -H "x-tdai-user-key: $TDAI_ADMIN_USER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"username":"developer"}' | jq
```

保存返回的 `data.default_user_key`。它通常只在创建响应中完整出现。普通用户登录 Panel 后创建的资产会按 owner/visibility 规则管理。

如果环境不允许将 `.env` source 到当前 shell，请把三个变量显式导出后执行 curl；不要把 key 直接写入 shell history。

## 4. 创建 Team、Agent 和 Task

推荐的最小组织结构：

```text
Team: my-project
├── Agent: builder
│   ├── Skill: feature-delivery
│   ├── Wiki: product-architecture
│   └── CodeGraph: my-project-repo
└── Task: implement-auth-refresh
```

使用顺序：

1. 创建 Team，并加入普通用户。
2. 创建 Agent，填写角色、目标、描述和边界；不要把 secret 写进 prompt。
3. 创建 Task，填写目标、验收标准、代码仓库或来源链接。
4. 将已经审核的 Skill/Wiki/CodeGraph 绑定到 Agent 的固定资产或 Team 共享资产。
5. 设置 `private`、`team` 或 `restricted` 可见性，确认 owner 和 ACL。
6. 第一次通过 Proxy 调用时，若开启了 `sessionInit`，根据表单选择 Team/Agent/Task；也可以通过请求头预选：

   ```text
   x-team-id: <team_id>
   x-agent-id: <agent_id>
   x-task-id: <task_id>
   ```

`sessionInit` 会校验这些 ID。值不存在时默认回到表单，而不是静默绑定到错误资产。

## 5. 导入 Wiki

在 Panel 的 Knowledge/Wiki 页面创建 Wiki，填写：

- 名称和 Team。
- 本地文件、内网 HTTP 源或内网 Git 文档源。
- owner 和可见性。
- 需要同步的目录/文件范围。

Knowledge 处理链路是：抓取源 → 切分/解析 → LLM 生成页面和摘要 → SQLite/FTS 索引 → 回调 Panel → Panel 将资产元数据写回 Core。处理完成后，再将 Wiki 绑定到 Team 或 Agent。

检查状态：

```bash
curl -sS http://127.0.0.1:8424/health
```

Swagger 地址：

```text
http://<宿主机地址>:8424/docs
```

`KNOWLEDGE_PUBLIC_BASE_URL` 必须包含 `/v3`，用于生成 Agent 可访问的 `service_url`。Knowledge 容器内部回调 Panel 使用 `http://memory-panel:8123`，不要填宿主机 `localhost`。

注意：Knowledge HTTP API 没有独立 token middleware。它应当只在 Docker 内网或受防火墙/反向代理 ACL 保护的网络中使用；不要把 8424 直接发布到公网。

## 6. 导入 CodeGraph

在 Panel 的 CodeGraph 页面创建代码图：

1. 选择 Team 和 owner。
2. 填写内网 Git URL 或可被 Knowledge 容器访问的仓库地址。
3. 配置分支/提交（如支持）和源目录。
4. 提交后等待 `building` → `ready` 或 `failed`。
5. 在 ready 后检查文件、符号、callers/callees 和影响路径。
6. 将 CodeGraph 资产绑定到 Builder/Reviewer Agent。

Knowledge 容器必须能够访问 Git 服务的 DNS、端口和凭据。宿主机能 `git clone` 不代表容器能 clone；排查时从容器网络验证，而不是只在宿主机上验证。

CodeGraph 任务完成后通过 `TMC_CALLBACK_URL` 回调 Panel。Panel 会以创建任务时暂存的 owner key 做资产登记；如果 Panel 重启导致内存任务表丢失，前端仍可用 register-meta 路径补登记，必要时在 Panel 日志中人工确认。

## 7. Skill 的审核和使用

Skill 不是一段随意 Prompt。建议包含：

- 适用场景和触发条件。
- 输入、步骤、边界和禁止事项。
- 需要读/写的工具。
- 验证命令或可观察的成功标准。
- 版本说明和回滚方式。

默认 `skillRuntime.allowLlmWrite=false`：模型可以检索、查看和读取 Skill，但不能直接创建、修改或删除 Skill。由人或受控后台审核后发布，降低低质量资产进入 Team 的风险。

Proxy 注入的 Skill 工具通过 `/skill-bridge` 进入 Proxy，再由 Proxy 注入 Core Bearer 和 service identity。不要把 Core gateway key 写进注入给 LLM 的文本。

## 8. Claude Code 接入

先准备一个普通用户的 `user_key`，并确认 Proxy 已启动且 `.env` 中：

```dotenv
TDAI_PROXY_PUBLIC_URL=http://<宿主机内网地址>:8096
```

临时 shell 接入：

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8096/claude-code/default
export ANTHROPIC_AUTH_TOKEN='<普通用户 user_key>'
claude
```

在 LAN 上使用时，把 `127.0.0.1` 替换为部署主机地址。Proxy 的路径格式是：

```text
http://<proxy-host>:8096/claude-code/<instance_id>
```

它会处理 `/v1/messages`，认证客户端 Bearer user key，调用 Core `auth/verify` 解析用户身份，再按 session/team/agent/task 注入记忆和资产，最后将模型请求转发到 `INTRANET_LLM_BASE_URL`。

如果 Claude Code 启动后收到 session-init 表单，按 Panel 中已创建的 Team/Agent/Task 选择；如果请求头能够提供 `x-team-id` 等身份，可跳过对应选择步骤。

## 9. OpenAI-compatible / CodeBuddy 接入

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8096/codebuddy/default/v1
export OPENAI_API_KEY='<普通用户 user_key>'
```

等价请求：

```bash
curl -sS http://127.0.0.1:8096/codebuddy/default/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "<内网模型名>",
    "messages": [{"role":"user","content":"请用一句话回复：记忆链路已接通。"}],
    "stream": false
  }'
```

真实业务请求的验收标准：

- Proxy 返回模型服务的合法响应，而不是 401/502。
- Core 的 L0 数据目录出现新的对话记录。
- Proxy 日志没有把完整 user key 或 LLM secret 写入请求正文日志。
- 重启 Core/Proxy 后仍能查询到持久化数据。

首次验证建议使用低成本模型、短 prompt 和 `stream:false`，完成链路后再切换真实 coding agent。

## 10. 直接验证 Core 双层认证

健康端点不需要 Core Bearer：

```bash
curl -sS http://127.0.0.1:8420/health | jq
```

Metadata/内部 API 同时需要服务 Bearer；公开用户路径还要 user key：

```bash
curl -sS -X POST http://127.0.0.1:8420/v3/meta/auth/verify \
  -H "Authorization: Bearer $TDAI_GATEWAY_API_KEY" \
  -H 'x-tdai-service-id: default' \
  -H 'Content-Type: application/json' \
  -d '{"user_key":"<普通用户 user_key>"}' | jq
```

预期 `code=0` 且 `data.valid=true`。没有 Core Bearer 的请求应为 401；不存在的 user key 也应被拒绝。不要因为 `/health` 200 就认为业务 API 已经过认证。

## 11. Knowledge Tools 和 Agent 自发现

Proxy 的 `knowledge` injector 从 Core 获取已登记的知识资产，向 Agent 提供 `knowledge_tools` 自发现块；工具实际调用 Knowledge 的 `/v3/tools/list` 和 `/v3/tools/call`。因此要让 Agent 使用 Wiki/CodeGraph，必须同时满足：

1. Knowledge 任务状态为 ready。
2. Panel 已把资产元数据写回 Core。
3. 资产对当前 user/team/agent 可见。
4. Proxy 的 `injection.enabled=true` 且包含 `knowledge`。
5. Agent 通过 Proxy，而不是直接调用上游 LLM。

排查顺序：Panel 资产状态 → Core 元数据 → Proxy 日志/health → Knowledge health/docs → 内网 LLM。

## 12. 记忆写入、召回和隐私边界

本 profile 的 Proxy 配置默认：

- `tdai.memory.writeL0=true`：把受控对话回写 Core L0。
- `tdai.memory.recallL1=true`：允许 L1 召回。
- `tdai.memory.injectL2L3=true`：把选定的 L2/L3 注入上下文。
- Proxy 的 TPM/QPM 限流在本 profile 默认关闭，因为实现依赖 Redis；需要限流时先接入内网 Redis，再按 Proxy 文档启用 `rateLimit`，不要在无 Redis 时直接改限额数字。
- `extraction.extractors=[skill, tdai-memory]`：允许对话结束后的 Skill/L0 回写。
- `sessionInit.enabled=true`：首次会话选择 Team/Agent/Task。

敏感信息治理建议：

- 不把密码、token、个人身份证、客户数据放进可共享 Memory/Skill/Wiki。
- 对有敏感内容的资产使用 `private` 或 `restricted`，不要只依赖 Agent 名称隔离。
- 生产 Agent 使用普通用户 key；admin key 只用于 Panel 运维和 bootstrap。
- 轮换 `TDAI_GATEWAY_API_KEY` 时同步更新 Panel 模板、Proxy auth 配置和所有部署副本，然后重启四服务。
- 轮换 user key 时撤销旧 key，并更新 Agent 客户端环境变量/Secret。

## 13. 常用运维命令

```bash
cd deploy/intranet

# 状态和日志
docker compose ps
docker compose logs -f memory-proxy
docker compose logs --tail=200 memory-core memory-knowledge memory-panel

# 重启单服务（不删除卷）
docker compose restart memory-proxy

# 停止但保留卷
docker compose stop

# 检查最终配置（不要把输出原样公开，里面有 secret）
docker compose config
```

不要使用 `docker compose down -v` 作为普通清理；它会删除数据卷。

## 14. 功能限制和何时扩展架构

当前内网 profile 是单机、单实例、SQLite/BM25。以下情况不能直接复制容器：

- 两台或更多 Proxy/Core 需要共享 session、锁和注入状态。
- 需要高可用 metadata 或多租户 service mode。
- Wiki/CodeGraph 数据量超出单机 SQLite/本地磁盘能力。
- 需要 COS/TCVDB/MongoDB/Redis 共享后端。

这时应单独规划共享数据库、对象存储、Redis、向量库、备份和迁移，启用对应私有扩展并重新做目标环境验收；不要把本地 SQLite profile 的 `restart: unless-stopped` 当成高可用方案。

## 15. 最小使用验收清单

| 场景 | 通过条件 |
| --- | --- |
| 管理员登录 | Panel 可打开，admin user key 可登录 |
| 普通用户 | 创建并使用普通 user key，旧 key 可按策略撤销 |
| Core 鉴权 | 无 Bearer 401；合法 Bearer + user key verify 200 |
| Proxy 边界 | 非法 user key 401；合法 key 到达内网 LLM |
| L0 | 真实受控请求后 Core 数据卷出现记录 |
| Skill | Skill 创建/审核/绑定后可在 Proxy 注入 |
| Wiki | ingest ready，Panel 收到 callback，资产可见 |
| CodeGraph | 内网 Git 可抓取，索引和 callers/callees 可查询 |
| 重启 | 四服务重启后数据、用户、资产和索引仍存在 |
| 无公网运行 | 运行期不需要 npm/apt/遥测；LLM 仅访问允许的内网地址 |
