# 故障排查

> 症状 → 原因 → 处理。先按 HTTP 状态码定位，再看 JSON-RPC 错误码与 tool 层。
> 请求/响应形状见 [protocol.md](protocol.md)；权限与配置见 [security.md](security.md)。

## 1. 症状速查

| 症状 | 最可能原因 | 去哪节 |
|---|---|---|
| `404 Not Found`（HTML 或 ICF 错误页） | ICF 节点不存在/未激活；endpoint 不存在 | §3 |
| `401 Unauthorized` | 未带 Basic 凭据 / 凭据错误 / ICF 登录过程要求其他认证 | §2 |
| `403 Forbidden` + `origin not allowed` | 浏览器 `Origin` 不在 `ORIGINS` 白名单 | §4 |
| `405 Method Not Allowed` | 用了 `GET`/`DELETE`；本服务只接受 `POST` | §5 |
| `406 Not Acceptable` | `Accept` 头明确排除了 `application/json` 与 `text/event-stream` | §6 |
| `415 Unsupported Media Type` | `Content-Type` 不是 `application/json` | §6 |
| `400` + `-32020` | modern 请求缺 `Mcp-Method`/`Mcp-Name` 头，或头与 body 不一致 | §7 |
| `400` + `-32022` | `MCP-Protocol-Version` / `_meta` 版本不在支持清单 | §7 |
| `400` + `-32700` | body 为空或不是合法 JSON | §8 |
| `-32601` | 方法名拼错，或 modern 请求里用了 `initialize`/`ping` | §9 |
| `-32602` + `unknown tool` | tool 名拼错、未注册、被 `READ_ONLY` 隐藏、注册到别的 endpoint | §10 |
| `isError: true` | 工具业务错误：参数非法、缺权限、数据不存在 | §10 |
| tool 不出现在 `tools/list` | 未注册、`TOOL_ENABLED` 为空、`READ_ONLY` 隐藏写工具、类未激活、`GET_META` 报错 | §11 |
| `500` + `-32603` | 服务器内部异常（ABAP dump） | §12 |

## 2. 认证与连接

**`401 Unauthorized`**

- 请求没带 `Authorization: Basic ...`（或 SSO 票据）。
- 用户名/密码错，或用户被锁；Basic 里的 base64 是 `user:password` 的 UTF-8 编码。
- ICF 节点上挂了非 Basic 的登录过程（例如要求 SPNEGO/证书）——客户端需要对应认证方式。
- 处理：先用浏览器/`curl -u` 直接访问根路径确认登录；`SU01` 查用户状态；`SICF` 查节点登录过程。

**`404` 但返回 HTML 或 ICF 登录页**

说明请求根本没到 MCP 处理器（见 §3）。

**连接被重置 / TLS 错误**

`STRUST` 证书、端口、host 配置问题；生产必须走 HTTPS（[security.md](security.md)）。

## 3. 404

| 场景 | 原因 | 处理 |
|---|---|---|
| `POST /sap/bc/mcp` 返回 HTML | ICF 节点未激活或路径拼错 | `SICF` → `/sap/bc/mcp` 激活；确认 handler class 是 `ZCL_AKIT_MCP_HTTP` |
| `POST /sap/bc/mcp/dev` 返回 `-32600 unknown MCP endpoint: dev` | 该 endpoint 在 `ZTAKIT_MCP_TOOL`/`ZTAKIT_MCP_CONF` 里没有行 | 跑 `abap run zcl_akit_mcp_setup` 播种 `dev`，或手工插注册表行 |
| modern 请求返回 `404` + `-32601` | modern 不支持 `initialize`/`ping`，或方法名拼错 | 改用 `server/discover` / `tools/list` / `tools/call` |
| `GET` 返回 `404` | 少数代理/网关把 `405` 改写成 `404` | 查网关；本服务本身对 `GET` 返回 `405` |

endpoint 名是 **URL 段**，转小写后匹配；注册表里也存小写。大小写混用不会匹配到。

## 4. 403

```json
{ "jsonrpc": "2.0", "id": null, "error": { "code": -32600, "message": "origin not allowed: configure ORIGINS to accept browser clients" } }
```

- 浏览器请求带了 `Origin`，但 `ORIGINS` 为空或不含该 origin。
- 处理：在 `ZTAKIT_MCP_CONF` 给对应 endpoint（或 `*`）配 `ORIGINS = https://app.example.com`；多个用逗号分隔。
- 纯 curl/桌面客户端一般不带 `Origin`，不会触发。
- 注意：`ORIGINS` 为空 = **拒绝**所有带 `Origin` 的请求（安全默认），不是「不校验」。

## 5. 405

- `GET` / `DELETE` / `PUT` / `PATCH` 一律 `405`，响应带 `Allow: POST, OPTIONS`。
- 本服务**不提供 SSE**，客户端用 `GET` 探活失败是预期行为；用 `POST` + `ping`（legacy）或 `server/discover`（modern）做存活探测。
- 客户端日志里出现 `405` 不影响后续 `POST` 调用。

## 6. 406/415

| 状态 | 触发 | 处理 |
|---|---|---|
| `406` | `Accept` 头存在且既不含 `application/json`、也不含 `text/event-stream` / `*/*` | 客户端改成 `Accept: application/json, text/event-stream`，或删掉 `Accept` 头 |
| `415` | `Content-Type` 存在且不含 `application/json` | 用 `Content-Type: application/json`；不要用 `text/plain` |

curl 调试时最容易忘 `-H 'Content-Type: application/json'`。

## 7. 400 / -32020 / -32022

**`-32020` Header mismatch**

modern 请求（`MCP-Protocol-Version: 2026-07-28`）必须镜像请求头：

```bash
-H 'MCP-Protocol-Version: 2026-07-28'
-H 'Mcp-Method: tools/call'
-H 'Mcp-Name: sap_info'          # tools/call 必需，且必须等于 params.name
```

- 缺 `MCP-Protocol-Version`、`Mcp-Method` → `-32020`。
- 头值与方法/`params.name` 不一致 → `-32020`。
- 头与 `params._meta` 的 `protocolVersion` 不一致 → `-32020`。
- legacy 客户端不要带 `Mcp-Method`/`Mcp-Name`；带了也会被忽略，但不要把它当 modern。

**`-32022` Unsupported protocol version**

- 请求头或 `_meta` 里的版本不在 `["2025-03-26","2025-06-18","2025-11-25","2026-07-28"]`。
- `error.data.supported` 列出了支持的版本；按它改客户端的版本设置。
- 典型原因：把 `draft` 或未来版本号写死进客户端配置。

**`-32602` 缺 `_meta`**

modern 请求必须带：

```json
"params": {
  "_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {}
  }
}
```

## 8. -32700 JSON 解析失败

- body 为空、不是 JSON、或是 JSON 数组（batch 不支持）。
- JSON 里 `jsonrpc` 必须是 `"2.0"`、必须有 `method`；`id` 为 `null` 是非法请求。
- 中文/特殊字符导致编码问题：确保 body 是 UTF-8，`Content-Type: application/json; charset=utf-8`。
- 用 `node scripts/akit-mcp.mjs --url … --user … raw '<body>'` 发送已知可用的 body 做对照。

## 9. -32601

- 方法名拼错：合法方法见 [protocol.md 第 5 节的方法矩阵](protocol.md#5-方法矩阵)。
- modern 请求里用了 `initialize` / `ping`：这两个方法只属于 legacy，modern 返回 `-32601` + `404`。
- legacy 请求里用了 `server/discover`：legacy 返回 `-32601` + `200`。
- `resources/*`、`prompts/*`、`tasks/*` 等本服务不支持，一律 `-32601`。

## 10. 未知 tool / isError

**`-32602 unknown tool: xxx`**

- tool 名大小写/拼写错误（MCP tool 名大小写敏感）。
- 注册表里没有该行，或 `TOOL_ENABLED` 不是 `X`。
- 工具注册在**别的 endpoint**（去对应 endpoint 的 `tools/list` 看）。
- 工具是写工具且当前 endpoint `READ_ONLY = X`（被当作未知）。

**`isError: true`**

业务错误，HTTP 仍是 `200`。看 `content[0].text` 里的消息：

| 消息关键字 | 原因 | 处理 |
|---|---|---|
| 授权/权限/not authorized | `AUTHORITY-CHECK` 失败 | 给用户补对应权限（见 [security.md](security.md)） |
| 参数/required/无效 | 参数缺失或格式不对 | 按 `tools/list` 的 `inputSchema` 填；必填字段不能省 |
| 不存在 / not found | 对象/表/事务码/T100 消息不存在 | 检查对象名；`ddic_get`/`object_search` 先确认拼写 |
| 行数/超过上限 | 返回行数超 `MAX_ROWS` | 缩小条件或加 `max_rows` 参数（不超过硬顶 5000） |
| 表不允许读取 | `table_read` 只接受透明表/视图 | 换透明表或视图；不要读池表/簇表 |

`isError` 是给模型自纠用的；错误消息应该可直接展示给用户，不应包含堆栈。

## 11. tool 不出现在 tools/list

按顺序排查：

1. **endpoint 对吗**：`ZTAKIT_MCP_TOOL.SERVER` 必须是请求的 endpoint（例如 `dev`）。
2. **`TOOL_ENABLED = 'X'`**：空 = 停用。
3. **`READ_ONLY = X` 且工具 `write = abap_true`**：写工具被隐藏（`ZTAKIT_MCP_CONF`）。
4. **类未激活**：`abap inspect ZCL_AKIT_MCP_TOOL_XXX --activation`；未激活的类会被跳过。
5. **`GET_META` 报错**：方法不存在/签名不对/返回空 `name` → 该工具被跳过，不拖垮列表；用 `abap run zcl_akit_mcp_setup` 看自检输出里的 `invalid[]`。
6. **DDIC 结构不存在**：`args_struct` 指错 → `build_schema` 退化为空 properties，但工具仍会出现；先修结构。

`zcl_akit_mcp_setup` 的自检 JSON 会列出每个注册行的校验结果，是排查注册问题最快的入口：

```bash
abap run zcl_akit_mcp_setup
# { "status":"ok", "endpoint":"dev", "url":"/sap/bc/mcp/dev", "tools":8, "added":0, "invalid":[] }
```

## 12. 500 / -32603

- 服务器内部未捕获异常（ABAP dump）。查 `ST22`，筛选 `ZCL_AKIT_MCP_*`。
- endpoint 被 `ENABLED` 关闭时也是 `503` + `-32603`：检查 `ZTAKIT_MCP_CONF` 的 `ENABLED`。
- 请求体超过 1 MB → `400`。
- 若 dump 在 `/UI2/CL_JSON`，先确认该类版本与系统 SAP_UI 版本匹配（[compatibility.md](compatibility.md)）。

## 13. 安装/激活相关

| 症状 | 原因 | 处理 |
|---|---|---|
| `abap run zcl_akit_mcp_setup` 报类不存在 | 还没推送/激活 | 先 `node scripts/install.mjs`，再跑 setup |
| setup 输出 `tools: 0` | 内置工具类未激活，或注册表行未创建 | 检查 8 个 `ZCL_AKIT_MCP_TOOL_*` 是否激活；重跑 install + setup |
| 语法错误：`/UI2/CL_JSON` 不存在 | 未装 SAP_UI 7.40+ | 安装 SAP_UI 组件后重推 |
| `abap push` 报 AFF 校验失败 | 源码文件名/格式不符合 AFF | `node scripts/check-aff.mjs` 本地先查 |
| `abap push` 报 `LOCK_FAILED: ... only in stateful mode` | abap-cli 复用了机器上遗留的失效 session jar（常见于多个 agent/窗口共享同一 profile） | `abap session reset --yes`，再重跑命令 |
| ICF 节点创建失败 | 节点已存在 / 权限不足 | `SICF` 手工建 `/sap/bc/mcp`，handler 填 `ZCL_AKIT_MCP_HTTP` |
| 改了工具类但行为没变 | 没激活，或 ICF 缓存 | `abap activate` 后重新请求；必要时 `SMICM` 清缓存 |

## 14. 拿到更多信息

- 先跑 `abap run zcl_akit_mcp_selftest`：它直接调协议层（不经过 ICF），能区分「协议/JSON/分发问题」与「HTTP/认证/ICF 问题」。自检通过但 HTTP 调用失败，问题基本在传输层或登录。
- 启用 HTTP 跟踪（`SMICM` → Trace），看请求是否到达 ICF、响应码是什么。
- 用 `scripts/akit-mcp.mjs` 复现（`tools` / `call <tool>` / `discover --modern` / `raw <json>`）：它打印原始响应，比客户端日志清楚。
- ABAP 侧错误：`ST22`；权限问题：`SU53`。
- 报问题前收集：SAP 版本/组件版本、`SICF` 节点状态、`zcl_akit_mcp_setup` 输出、一条最小 curl 请求与完整响应。
