# 真机验证记录

> 本页记录 v1.0.0 在真实 SAP 系统上的验证结果与可复现步骤，不是承诺。
> 环境不同（组件版本、登录过程、权限）结果会不同；ECC 未验证，见 [compatibility.md](compatibility.md)。

## 1. 验证环境

| 项 | 值 |
|---|---|
| 系统 | S/4HANA，SAP_BASIS **757**（ABAP 平台版本），`SY-SYSID = S4H` |
| Client / 用户 | `100` / `SAP103`（测试账号，开发权限） |
| 组件依赖 | SAP_UI 7.40+（`/UI2/CL_JSON` 可用） |
| abap-cli | 2.6.1（`abap` 命令） |
| Node.js | >= 20（安装器与调试客户端） |
| 部署包 | `$TMP`（本地对象，免传输） |

```bash
abap whoami   # profile test → S4H / 100 / SAP103 / 757
```

## 2. 部署与播种

```bash
node scripts/install.mjs --yes
# AKIT MCP installer — 29 objects, package $TMP
# created HTTP ZAKIT_MCP            （ICF 节点；已存在时执行 updated）
# Objects: 1 created, 28 existing, 0 failed.

abap run zcl_akit_mcp_setup
# {"status":"ok","endpoint":"dev","url":"/sap/bc/mcp/dev","tools":8}
```

- 29 个对象：18 个类（框架 10 + 8 个内置工具）、2 张透明表、7 个入参结构、1 个上下文报表、1 个 ICF 节点。
- `install.mjs` 幂等：重复执行只推送变更、复用已存在对象；`zcl_akit_mcp_setup` 重跑不重复播种（`added` 为空）。
- ICF 节点 `ZAKIT_MCP` → `/sap/bc/mcp`，handler `ZCL_AKIT_MCP_HTTP`。

## 3. 协议回归（`abap run zcl_akit_mcp_selftest`）

不经过 HTTP，直接调用 `ZCL_AKIT_MCP_SERVER=>handle( )`；输出 26 行 camelCase JSON（每行一个用例）。

| 用例 | HTTP | 断言 |
|---|---|---|
| `legacy_initialize` | 200 | `protocolVersion = 2025-11-25`，capabilities 只有 `tools`，含 serverInfo/instructions |
| `legacy_notification` | 202 | 无 id 的通知 → 202 空 body |
| `legacy_ping` | 200 | `{}` |
| `legacy_tools_list` | 200 | 8 个 tool，inputSchema 带 `required` 与字段描述，annotations 显式 |
| `legacy_tools_call_sap_info` | 200 | `content[].text` + `structuredContent`，`isError:false` |
| `legacy_unknown_tool` | 200 | `-32602` unknown tool |
| `legacy_unknown_method` | 200 | `-32601` |
| `invalid_json` | 400 | `-32700` |
| `null_id` | 400 | `-32600` |
| `unsupported_version` | 400 | `-32022` + `data.supported/requested` |
| `initialize_counter_offer` | 200 | 请求 `2026-07-28` → 回 `2025-11-25`（不报错） |
| `modern_discover` | 200 | `supportedVersions`、`resultType`、`ttlMs`、`cacheScope`、`_meta.serverInfo` |
| `modern_tools_list` | 200 | 同上信封，tools 与 legacy 一致 |
| `modern_initialize_is_404` | 404 | `-32601`（modern 无 initialize） |
| `modern_header_mismatch` | 400 | `-32020`（`Mcp-Method` 与 body 不一致） |
| `unknown_endpoint` | 404 | `-32600` unknown MCP endpoint |
| `root_catalogue` | 200 | 根路径返回 endpoint 目录（非 MCP） |
| `tool_object_search` | 200 | 命中 `ZCL_AKIT_MCP_*` 类，含描述 |
| `tool_source_read` | 200 | active 版本源码前 5 行，`truncated=true` |
| `tool_syntax_check` | 200 | `valid=true` |
| `tool_syntax_check_invalid` | 200 | `valid=false` + `returnCode/line/word/message`（字段稳定出现） |
| `tool_ddic_get` | 200 | `DD03L` 元数据 + 中文字段描述 |
| `tool_table_read` | 200 | `T000` 前 5 行，`rowCount=5`、`truncated=true` |
| `tool_tcode_info` | 200 | `SE38` → 程序/屏幕/文本 |
| `tool_message_text` | 200 | `00/001` 消息文本 |
| `tool_object_search_empty` | 200 | 零命中 → `{"objects":[],"count":0,"truncated":false}`（稳定形状） |

结论：26/26 符合预期（`legacy_notification` 的 202 也是预期值）。

## 4. 内置工具冒烟（真实返回摘录）

```json
// table_read {"tableName":"T000","fields":"MANDT,MTEXT","maxRows":5}
{"tableName":"T000","rows":[{"mandt":"000","mtext":"SAP AG"}, ...],"rowCount":5,"truncated":true}

// tcode_info {"tcode":"SE38"}
{"tcode":"SE38","description":"ABAP 编辑器","program":"RSABAPPROGRAM","dynpro":"1000",
 "programTitle":"ABAP 编辑器中的报表事务初始屏幕"}

// syntax_check {"source":"DATA gv TYPE i.\ngv = ."}
{"valid":false,"returnCode":4,"line":1,"word":"DATA",
 "message":"The REPORT/PROGRAM statement is missing, or the program type is INCLUDE.",
 "lineCount":2,"program":"ZAKIT_MCP_SYNTAX_CONTEXT"}
```

`sap_info` 返回 `S4H / 100 / SAP103 / 757 / HDB`；`ddic_get {'objectName':'DD03L'}` 返回完整字段清单与中文描述；`object_search` 命中本仓库自身类。

## 5. HTTP / ICF 层

| 请求 | 结果 | 说明 |
|---|---|---|
| `GET /sap/bc/mcp`（无凭据） | `401` + Basic challenge | 节点存在、handler 已装配、登录过程为 Basic |
| `POST /sap/bc/mcp/dev`（无凭据） | `401` | endpoint 路由未到达（认证在前） |
| `POST /sap/bc/mcp/dev`（带账号） | 未验证 | 测试系统无可用的提交凭据；用户用自己账号验证 |

带认证的端到端（用户在有凭据的环境执行）：

```bash
node scripts/akit-mcp.mjs --url https://<host>:<port>/sap/bc/mcp/dev --user <user> tools
node scripts/akit-mcp.mjs --url https://<host>:<port>/sap/bc/mcp/dev --user <user> call sap_info
node scripts/akit-mcp.mjs --url https://<host>:<port>/sap/bc/mcp/dev --user <user> --modern discover
```

也可以用裸 curl：

```bash
curl -u <user>:<password> -k -X POST 'https://<host>:<port>/sap/bc/mcp/dev' \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## 6. 未验证项

- **ECC EHP8 / SAP_BASIS 7.50 真机**：本仓库只用 7.40+ 经典 API，但未在 ECC 系统实测；见 [compatibility.md](compatibility.md)。
- **带认证的 HTTP 端到端**：只做了 401 可达性探测。
- **多客户端兼容**：Claude Code / Cursor / VS Code 的配置方式见 README，但未逐一连真机（协议层按规范实现）。
- **N 个并发请求 / 大表查询 / 1500 行以上源码**：未做压力与上限实测；受 `MAX_ROWS`（默认 200，硬顶 5000）与 `source_read` 5000 行限制。

## 7. 复现步骤

```bash
git clone <repo> && cd akit-mcp
abap init --profile <profile> --package '$TMP'
node scripts/install.mjs
abap run zcl_akit_mcp_setup
abap run zcl_akit_mcp_selftest
npm run verify
```
