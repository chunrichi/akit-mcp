# 协议实现：MCP over Streamable HTTP

> 本文描述 akit-mcp **实际实现**的 MCP 传输与协议形状：哪些方法支持、哪些头要校验、错误码怎么回。
> 协议契约变更先改 [design.md](design.md)，再改本文；研究对象稿不对外。

## 1. 支持的版本与 era

MCP 协议有两个互不兼容的「代」（era）。akit-mcp **同时实现两代**，但每个请求独立判定，不保存协商结果（无 session）。

| era | 版本 | 判据 | 响应数据形状 |
|---|---|---|---|
| legacy | `2025-03-26` / `2025-06-18` / `2025-11-25` | 请求是 `initialize`；或请求没有声明 modern 版本 | 统一按 `2025-11-25` 形状回复（旧客户端忽略未知字段） |
| modern | `2026-07-28` | `MCP-Protocol-Version` 请求头或 `params._meta` 里声明 `2026-07-28` | modern 结果信封（`resultType` 等） |

规则细节：

- **`initialize` 只属于 legacy**。客户端请求的版本若不是三个 legacy 版本之一，服务器**不报错**，而是 counter-offer 我方最新 legacy 版本 `2025-11-25`——这是规范要求的版本协商语义，客户端不接受时由客户端断开。
- modern 请求**必须**同时带请求头与 `_meta` 版本声明，缺一或两者不一致都会在传输层被拒（见第 2、4 节）。
- 不支持的版本 → HTTP `400` + `-32022`，`error.data.supported` 给出支持清单。
- 未声明版本的非 `initialize` 请求按 **legacy** 处理。这是无状态实现的有意选择：`2025-06-18` 及之后的客户端本来就必须在握手后带 `MCP-Protocol-Version` 头。
- 不在支持清单里的版本（如 `2024-11-05`、`draft`）不予实现。

## 2. 传输层

### 2.1 ICF 节点与 endpoint 路由

```text
POST https://<host>:<port>/sap/bc/mcp/<endpoint>
```

- ICF 节点 `/sap/bc/mcp` 由 `abap/src/zakit_mcp.http.json` 声明，处理器类 `ZCL_AKIT_MCP_HTTP`（`IF_HTTP_EXTENSION`）。
- `<endpoint>` 是 URL 路径段，例如 `dev`；每个 endpoint 在注册表 `ZTAKIT_MCP_TOOL` 里有一套工具，在配置表 `ZTAKIT_MCP_CONF` 里有一套配置。请求里的 endpoint 会转小写后匹配。
- **根路径 `/sap/bc/mcp` 不是 MCP 协议**：它返回 endpoint 目录 JSON，便于人/agent 发现有哪些服务：

```json
{
  "servers": [
    { "name": "dev", "title": "AKIT MCP - dev", "tools": 8 }
  ],
  "hint": "POST /sap/bc/mcp/<endpoint> with MCP JSON-RPC (initialize, tools/list, tools/call)."
}
```

- endpoint 名只允许 **一个 URL 段**、小写字母/数字/`-`/`_`、最长 30 字符（与 `SERVER` 字段一致）；路径更深或含非法字符 → HTTP `404` + `-32600`（`unknown MCP endpoint path; expected /sap/bc/mcp/<endpoint>`）。
- endpoint 不存在（注册表与配置表都没有该 SERVER）→ HTTP `404` + JSON-RPC 错误 `-32600`。
- endpoint 存在但 `ENABLED` 不是 `X` → HTTP `503` + `-32603`。
- 根目录只列出**至少有一个启用 tool** 的 endpoint。
- 根路径 `GET` 与 `POST` 都返回这份目录（`POST` 的 body 被忽略）；endpoint 路径本身只接受 `POST`。

### 2.2 HTTP 方法与响应头

| 方法 | 行为 |
|---|---|
| `POST` | MCP 入口：一个 JSON-RPC 请求/通知进，一个 HTTP 响应出（根路径的 `POST` 例外，返回目录） |
| `OPTIONS` | CORS 预检，`204` + `Allow: POST, OPTIONS` |
| `GET` / `HEAD` | 根路径：返回 endpoint 目录（`200`）；endpoint 路径：`405` + `Allow: POST, OPTIONS`（不提供 SSE 流） |
| `DELETE` | `405` + `Allow: POST, OPTIONS`（无会话可终止） |
| 其他 | `405` + `Allow: POST, OPTIONS` |

正常响应统一带 `Content-Type: application/json; charset=utf-8`、`Cache-Control: no-store`、`X-Akit-Mcp-Version: 1.0.0`；`202` 通知响应为**空 body**、不带 `Content-Type`。

### 2.3 请求头校验

| 头 | 校验方式 | 失败 |
|---|---|---|
| `Content-Type` | `POST` 时若非空且不含 `application/json` | `415` |
| `Accept` | 仅当存在、且既不含 `application/json`、也不含 `text/event-stream` / `*/*` | `406` |
| `MCP-Protocol-Version` | legacy 传输层不强制；modern 必须存在且等于 `_meta` 版本 | `400` / `-32020` / `-32022` |
| `Mcp-Method` | modern 必须存在且等于 JSON-RPC `method` | `400` / `-32020` |
| `Mcp-Name` | modern 的 `tools/call` 必须存在且等于 `params.name` | `400` / `-32020` |
| `Origin` | 配置了 `ORIGINS` 时必须是白名单成员（大小写不敏感） | `403` |
| `Mcp-Session-Id` / `Last-Event-ID` / `Mcp-Param-*` | 忽略：不校验、不回显、不新建 | — |
| `Authorization` | 不归 MCP 层管，交给 ICF 登录（Basic / SSO） | ICF `401` |

`Accept` 的宽松校验是有意为之：规范把它写成客户端的义务，严格校验只会让 curl 等脚本客户端出现假故障。

### 2.4 HTTP 状态码

| 场景 | HTTP | body |
|---|---|---|
| JSON-RPC 成功（`initialize` / `ping` / `tools/*` / `server/discover`） | `200` | JSON-RPC result |
| 通知（任何无 `id` 的消息） | `202` | 空 |
| JSON-RPC 应用错误（`-32600` / `-32602` / `-32603`，legacy `-32601`） | `200` | JSON-RPC error |
| modern 未知方法 | `404` | `-32601` |
| 传输/版本/头校验失败（modern） | `400` | `-32020` / `-32021` / `-32022` / `-32602` |
| body 为空或不是合法 JSON | `400` | `-32700` |
| Origin 不在白名单 | `403` | JSON-RPC error（`id` 为 `null`） |
| endpoint 不存在 | `404` | `-32600` |
| `ENABLED` 关闭 | `503` | `-32603` |
| endpoint 路径上的 `GET` / `DELETE` / 其他方法 | `405` | JSON-RPC error + `Allow` |
| 非法 endpoint 路径（多段/非法字符/超长） | `404` | `-32600` |
| `Content-Type` 非 JSON | `415` | JSON-RPC error |
| `Accept` 排除 JSON 与 `text/event-stream` | `406` | JSON-RPC error |
| HTTP 层未捕获异常 | `500` | `-32603` |

要点：**只有传输/版本/头/HTTP 方法层失败才用 4xx/5xx**。`tools/call` 的业务错误一律 `200` + `isError:true`，否则客户端会当传输故障重试。

## 3. legacy era 方法

### 3.1 `initialize`

请求 `params`：`protocolVersion`（必填）、`capabilities`、`clientInfo`。

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": { "name": "curl", "version": "0" }
  }
}
```

响应 `result`：

| 字段 | 取值 |
|---|---|
| `protocolVersion` | 回显客户端支持的版本；不支持时回 `2025-11-25` |
| `capabilities` | 只声明 `{"tools":{}}`；不声明 `listChanged`、logging、resources、prompts、completions |
| `serverInfo` | `{ "name": "akit-mcp", "title": "<endpoint TITLE>", "version": "1.0.0" }` |
| `instructions` | 配置项 `INSTRUCTIONS` 的值；未配置时给一句内置说明 |

缺 `protocolVersion` → `200` + `-32602`。

### 3.2 `notifications/initialized` 与其他通知

任何**没有 `id`** 的 JSON-RPC 消息（`notifications/initialized`、`notifications/cancelled`、`notifications/progress` …）都返回 `202` 空 body，且不产生任何副作用。无状态实现不需要初始化通知，但必须接受它，否则客户端会卡在握手。

### 3.3 `ping`

```json
{ "jsonrpc": "2.0", "id": 2, "method": "ping" }
```

响应 `result` 为 `{}`。modern era 已删除 `ping`，在 modern 请求里调用会得到 `-32601` + `404`。

### 3.4 `tools/list`

响应 `result.tools[]`，每个元素：

| 字段 | 说明 |
|---|---|
| `name` | tool 名，小写 snake_case，例如 `table_read` |
| `title` | 展示名（中文） |
| `description` | 给模型看的用途与边界（中文） |
| `inputSchema` | 从入参 DDIC 结构自动生成的 JSON Schema，根为 `type: "object"` |
| `annotations` | 显式给 `readOnlyHint` / `destructiveHint` / `openWorldHint`，不依赖协议默认值 |

排序按注册表 `TOOL_SORT` 升序、再按 `TOOL_CLASS` 升序，结果稳定。工具数量远小于一页，**不分页**，不返回 `nextCursor`；`cursor` 参数被忽略。

`annotations` 的规则：只读工具 `readOnlyHint: true`、`destructiveHint: false`、`openWorldHint: false`；`write = true` 的工具取反。`READ_ONLY = X` 时写工具**不出现**在 `tools/list`。

### 3.5 `tools/call`

请求 `params`：`name`（必填）、`arguments`（JSON 对象，缺省按 `{}`）。

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": { "name": "sap_info", "arguments": {} }
}
```

响应 `result`（`CallToolResult`）：

| 字段 | 说明 |
|---|---|
| `content` | `[{ "type": "text", "text": "<工具返回的 JSON 文本>" }]` |
| `structuredContent` | 仅当工具返回的是 **JSON 对象**时出现，与 `content[0].text` 同源；数组/标量只有 text |
| `isError` | 仅失败时出现且为 `true`；缺省即成功 |

错误的归属（最容易做反的地方）：

| 情形 | 返回 |
|---|---|
| 未知 tool 名 / 缺 `params.name` | JSON-RPC 错误 `-32602`（HTTP `200`） |
| `arguments` 不是 JSON 对象 | `isError: true` 的 CallToolResult |
| 参数通过结构校验但业务上非法 | `isError: true`（模型可自纠） |
| tool 内抛 `ZCX_AKIT_MCP_TOOL_ERROR` / 其他 `CX_ROOT` | `isError: true` + 人类可读消息 |
| 工具返回的 JSON 文本不是对象 | 正常 text 结果，无 `structuredContent` |

`READ_ONLY = X` 时写工具被当作「未知 tool」拒绝（`-32602`），不会泄露其存在。

## 4. modern era 方法

modern（`2026-07-28`）把版本协商从握手挪到了每个请求里，因此**没有** `initialize`、`notifications/initialized`、`ping`、session。

### 4.1 每请求 `_meta`

每个 modern 请求的 `params._meta` 必须包含：

| Key | 要求 | 失败 |
|---|---|---|
| `io.modelcontextprotocol/protocolVersion` | 字符串，必须等于 `MCP-Protocol-Version` 头 | 缺失 `-32602`；不等 `-32020` |
| `io.modelcontextprotocol/clientCapabilities` | 对象（可为 `{}`） | 缺失 `-32602` |

`clientInfo`、`logLevel`、`traceparent` 等可选键被接受并忽略（本服务不产日志、不做采样）。

### 4.2 头镜像

modern 请求的 HTTP 头必须镜像 body 内容：

| 头 | 取自 | 必需 |
|---|---|---|
| `MCP-Protocol-Version` | `params._meta` 的协议版本 | 所有请求 |
| `Mcp-Method` | JSON-RPC `method` | 所有请求 |
| `Mcp-Name` | `params.name`（`tools/call`） | `tools/call` 必需 |
| `Mcp-Param-*` | 声明了 `x-mcp-header` 的 tool 参数 | 本服务**不声明**任何 `x-mcp-header`，不校验 |

头名大小写不敏感，头值大小写敏感。缺失或不一致 → HTTP `400` + `-32020`。

### 4.3 `server/discover`

modern 客户端用它做 era 探测（Claude Code v2、DeepSeek Harness 都会先发）。请求除 `_meta` 外无业务参数；响应 `result`：

| 字段 | 取值 |
|---|---|
| `supportedVersions` | `["2025-03-26","2025-06-18","2025-11-25","2026-07-28"]` |
| `capabilities` | `{"tools":{}}` |
| `instructions` | 同 legacy `initialize` |
| `resultType` | `"complete"` |
| `ttlMs` / `cacheScope` | `0` / `"private"` |
| `_meta["io.modelcontextprotocol/serverInfo"]` | `{name,title,version}` |

modern `initialize`、`ping` 均不支持：`-32601` + HTTP `404`。

### 4.4 modern 结果信封

每个 modern 结果都带：

| 字段 | 何时出现 | 取值 |
|---|---|---|
| `resultType` | 所有 modern result | `"complete"`（本服务不做 MRTR/`input_required`） |
| `ttlMs` / `cacheScope` | 可缓存结果：`server/discover`、`tools/list` | `0` / `"private"` |
| `_meta["io.modelcontextprotocol/serverInfo"]` | 所有 modern result | `{name,title,version}` |

`tools/call` **不可缓存**，不加 `ttlMs` / `cacheScope`。

## 5. 方法矩阵

| 方法 | legacy | modern | 说明 |
|---|---|---|---|
| `initialize` | ✅ | —（`-32601` + `404`） | 版本协商、能力声明、instructions |
| `notifications/initialized` | ✅ `202` | — | 接受后丢弃，无副作用 |
| `ping` | ✅ `{}` | —（`-32601` + `404`） | 存活探测 |
| `tools/list` | ✅ | ✅ | 工具定义来自注册表 + DDIC → JSON Schema |
| `tools/call` | ✅ | ✅ | 参数反序列化 → 动态 `CALL METHOD` |
| `server/discover` | —（`-32601`） | ✅ | version/capabilities + modern 信封 |
| 其他方法 | `-32601`（HTTP `200`） | `-32601`（HTTP `404`） | 明确不支持 |

## 6. 错误码

| code | 名称 | 何时出现 | HTTP |
|---|---|---|---|
| `-32700` | Parse error | body 为空、不是合法 JSON、或解析后既无 `jsonrpc` 也无 `method` | `400` |
| `-32600` | Invalid request | 缺 `jsonrpc`（≠`2.0`）/缺 `method`/`id` 为 `null`/endpoint 不存在 | `200`（endpoint 不存在为 `404`） |
| `-32601` | Method not found | 未知方法；modern 的 `initialize` / `ping` | legacy `200`；modern `404` |
| `-32602` | Invalid params | 缺 `params.name`、未知 tool、modern `_meta` 缺必填、`initialize` 缺版本 | `200`；modern `_meta` 缺失为 `400` |
| `-32603` | Internal error | 服务器自身异常；endpoint 被 `ENABLED` 关闭时用 `503` | `200` / `503` |
| `-32020` | Header mismatch | modern 头缺失、与 body 不一致 | `400` |
| `-32021` | Missing required client capability | 预留：本服务不实现 MRTR，不会发出 | — |
| `-32022` | Unsupported protocol version | 版本未知/不支持 | `400`，带 `data` |

错误对象形状：

```json
{ "jsonrpc": "2.0", "id": 1, "error": { "code": -32602, "message": "unknown tool: stock_chek" } }
```

收到非法 `id`（对象/数组）时，`id` 回 `null`；合法字符串/数字 `id` 原样回显（类型保持）。

`-32022` 必须带 `data`：

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "error": {
    "code": -32022,
    "message": "unsupported protocol version: 2026-01-01",
    "data": {
      "supported": ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"],
      "requested": "2026-01-01"
    }
  }
}
```

自定义错误码：本服务只用 JSON-RPC 标准码与 `-32020`/`-32022`；tool 业务错误走 `isError`，不发明新错误码。

## 7. 无 SSE、无 session 的合规边界

MCP Streamable HTTP 规范把会话与推送都写成可选/条件能力，因此「无状态 + 无 SSE」是**规范允许**的实现，不是偷工减料：

| 能力 | 本服务 | 依据 |
|---|---|---|
| SSE（`GET` 长连接） | 不提供；endpoint 上的 `GET` → `405` + `Allow`（根路径 `GET` 只返回 endpoint 目录） | 规范：服务器 MUST 要么返回 `text/event-stream`，要么返回 405 |
| `Mcp-Session-Id` | 从不发送；收到忽略；不建 ICF 会话（`set_session_stateful` 关闭） | 规范：server **MAY** assign a session ID |
| 服务端推送（`notifications/*`） | 不发送任何一条 | 无 SSE 通道 |
| `resources` / `prompts` / `tasks` / `sampling` / `elicitation` / `logging` | 不声明、不支持 → `-32601` | 只暴露 `tools` 能力 |
| `tools.listChanged` | 不声明（等价 `false`） | 无推送通道 |
| `subscriptions/listen`（modern） | 不支持 → `-32601` | 需要长连接流 |
| `DELETE` | `405` | 规范允许服务器拒绝会话终止 |

由此产生的已知代价（写进文档而不是藏起来）：

- 后台加 tool 后，客户端要**重连/重拉** `tools/list` 才能看到（无 `listChanged`）。
- 没有 `resources`/`prompts`，模型只能通过 tool 取数据。
- 认证只走 ICF 登录（Basic / SSO），未实现 OAuth；OAuth-only 的客户端（如 ChatGPT 自定义 connector）需要前置网关。
- `createMessage`/sampling 等 server→client 请求不可能发生。

## 8. 验收 curl 序列

以下命令在已安装并播种的 S/4HANA 系统上可直接跑（`-u` 走 ICF Basic 登录；`$URL` 换成实际主机端口）。

```bash
U='https://<host>:<port>/sap/bc/mcp/dev'
A='-u <user>:<password>'

# 0. 根路径：endpoint 目录（非 MCP 协议）
curl -s $A 'https://<host>:<port>/sap/bc/mcp'

# 1. initialize
curl -s $A -X POST "$U" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

# 2. notifications/initialized：必须 202 且空 body
curl -s -o /dev/null -w '%{http_code}\n' $A -X POST "$U" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# 3. tools/list
curl -s $A -X POST "$U" -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 4. tools/call
curl -s $A -X POST "$U" -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sap_info","arguments":{}}}'

# 5. modern：server/discover（头必须镜像 body）
curl -s $A -X POST "$U" -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' \
  -d '{"jsonrpc":"2.0","id":4,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'

# 6. endpoint 上的 GET 必须 405 且带 Allow
curl -s -o /dev/null -D - $A "$U" | grep -i '^allow:'
```

日常调试更推荐仓库自带的客户端（内部完成 `initialize` 握手，输出原始 JSON）：

```bash
M='node scripts/akit-mcp.mjs --url https://<host>:<port>/sap/bc/mcp/dev --user <user> --password <password>'
$M tools                                   # initialize + tools/list
$M call sap_info                           # tools/call，第二个实参是 JSON 参数
$M call table_read '{"tableName":"T000","maxRows":5}'
$M discover --modern                       # 2026-07-28 的 server/discover
$M raw '{"jsonrpc":"2.0","id":9,"method":"ping"}'   # 发任意 JSON-RPC body
```

`--password` 省略时在 TTY 里交互输入；也可用环境变量 `AKIT_MCP_URL` / `AKIT_MCP_USER` / `AKIT_MCP_PASSWORD`。自签证书加 `--insecure`。

## 9. 与客户端的版本兼容

| 客户端 | 走的 era | 说明 |
|---|---|---|
| Claude Code | legacy（v1 运行时）或 modern（v2 运行时） | v2 先探测 `server/discover`，形状不对可自动降级 legacy |
| Cursor | legacy | 支持 Streamable HTTP，不强制 SSE |
| VS Code / Copilot | legacy | 先试 HTTP，失败才回退 SSE |
| DeepSeek Harness | modern → legacy | 探测失败时降级，两代都能连 |

所有主流客户端都能完成 `initialize → tools/list → tools/call` 三步；「无 SSE」不是兼容性障碍，**无 session 的代价只是没有推送**。各客户端配置方法见 [README](../README.md#connect-a-client)。
