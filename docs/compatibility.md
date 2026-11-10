# 兼容性

> 目标：**ECC EHP8（SAP_BASIS 7.50）/ S/4HANA** 上的常规 ABAP 系统。
> 本文写清最低版本、依赖组件、已/未验证项；「未验证」不是「不支持」，但没有真机证据就不说验证过。

## 1. 最低版本与依赖

| 组件 | 最低版本 | 用途 | 验证状态 |
|---|---|---|---|
| SAP_BASIS | **7.50**（ECC EHP8 / S/4HANA） | 框架与内置工具的运行时：ICF、类运行时、DDIC、AUTHORITY-CHECK | **S/4HANA 已验证；ECC 未真机验证** |
| SAP_UI | **7.40** | `/UI2/CL_JSON`（JSON 解析/序列化）；框架不自己实现 JSON 解析器 | S/4HANA 已验证 |
| abap-cli | 2.x（见仓库 README 的安装说明） | 推送/激活 AFF 对象、`abap run` 执行 setup | S/4HANA 已验证 |
| Node.js | **>= 20**（`package.json` `engines`） | `scripts/install.mjs` / `akit-mcp.mjs` / 校验脚本 | CI（node 20）与本地 |
| 浏览器/客户端 | 任意支持 Streamable HTTP + Basic auth 的 MCP 客户端 | Claude Code / Cursor / VS Code 等 | 未逐客户端抓包验证 |

> `/UI2/CL_JSON` 属于 **SAP_UI** 组件而不是 SAP_BASIS。SAP_UI 7.40 起提供该类；如果系统里没有这个类，推送时会直接语法错误（见 [troubleshooting.md](troubleshooting.md)）。

内置工具还会用到这些 SAP_BASIS 7.40+ 的经典能力：

| 工具 | 依赖 | 说明 |
|---|---|---|
| `source_read` | `CL_OO_FACTORY` / `IF_OO_CLIF_SOURCE_FACTORY` | ADT 类源码接口，读 CLAS/INTF 的 active 版本源码（SAP_BASIS 7.40+） |
| `source_read` | `RPY_PROGRAM_READ` | 读报表程序源码（经典函数模块） |
| `syntax_check` | `SYNTAX-CHECK` + 上下文报表 `ZAKIT_MCP_SYNTAX_CONTEXT` | 语法检查需要 REPORT 作为上下文，类池不适用 |
| `object_search` | `TADIR` + `SEOCLASSTX` / `TRDIRT` / `DD02T` / `DD04T` 等 | 对象清单与描述文本，按对象类型取对应文本表 |
| `ddic_get` / `table_read` | `DD02L` / `DD03L` / `DD04L` | 元数据与字段清单 |
| `tcode_info` | `TSTC` / `TSTCT` / `TRDIRT` | 事务码、程序与文本 |
| `message_text` | `T100A` / `T100` | 消息类与消息文本 |

## 2. /UI2/CL_JSON 依赖

框架用它做两件事：

1. **序列化**：响应、tool 返回值、JSON Schema 片段都由 `/UI2/CL_JSON=>SERIALIZE` 输出（`pretty_mode-camel_case`）。业务数据用 `compress` 省略初始值；协议信封与内置工具结果用 `to_json_full` 保留 `false`/`0`/空数组，保证文档里的字段形状稳定。
2. **反序列化**：JSON-RPC 请求体、`params.arguments` 反序列化到 ABAP 结构。modern 的 `_meta` 是唯一例外：JSON 成员名是 `io.modelcontextprotocol/...` 命名空间键，而 typed deserialize 不应用 `name_mappings`（映射只在动态 `GENERATE`/`REF TO DATA` 路径生效），所以框架先文本提取 `params._meta`、去掉命名空间前缀，再反序列化到 `ty_meta`。

上游参考：SAP 官方开源版 [SAP/abap-to-json](https://github.com/SAP/abap-to-json)（类 `Z_UI2_JSON`，与交付的 `/UI2/CL_JSON` 同源；`docs/basic.md`、`docs/advanced.md` 就是 `/UI2/CL_JSON` 的公开文档）。本框架遵循其文档要点：序列化/反序列化使用同一个 `pretty_mode`（camel_case）；不启用 `conversion_exits`；不做 `format_output`（固定紧凑 JSON）。静态 `SERIALIZE`/`DESERIALIZE` 每次内部都会 new 一个实例，单请求调用次数固定（≤2），可接受；批量场景可改用实例方法（`DESERIALIZE_INT`/`SERIALIZE_INT`）优化。

已知边界：

- 交付的 7.57 版本 `/UI2/CL_JSON` 比 `SAP/abap-to-json` 当前 `main` 旧（后者新增 `STRICT_MODE`、`DISALLOW_UNKNOWN`、`DISABLE_STRING_TYPE_DETECT` 等，见其 README 与 `docs/advanced.md`）；框架不依赖这些新参数。
- typed deserialize 不会应用 `name_mappings`；需要 `_meta`/`$schema` 这类非法 ABAP 名时自己做提取（本框架的做法见上）。
- 字符串转义与 Unicode 由类内部处理；`&` 不会被转成 `&amp;`（ADT classrun 控制台会显示成 `&amp;`，那是控制台转义，不是 cl_json）。

因此：

- 目标系统必须安装 SAP_UI 7.40+，且 `/UI2/CL_JSON` 已激活（`SE24` 可查）。
- 升级 SAP_UI 一般不需要改框架；行为变化时回归 `initialize`/`tools/list`/`tools/call` 三条请求即可。
- 中文/特殊字符：`/UI2/CL_JSON` 输出 UTF-8 JSON，响应头固定 `application/json; charset=utf-8`。

## 3. S/4HANA 已验证项

在 S/4HANA（abap-cli profile `test`）上完成过以下验证：

- **安装链**：AFF 源码可被 `abap-cli` 推送与激活（框架类、表、DDIC 结构、ICF 节点定义）。
- **ICF 节点**：`/sap/bc/mcp` 节点已创建并可达；未认证请求返回 `401`，证明节点与 handler 已生效。
- **播种**：`abap run zcl_akit_mcp_setup` 幂等播种内置工具到 `dev` endpoint、写一条 `TITLE` 配置行，并输出自检 JSON（`status`、`endpoint`、`url`、`tools`、`added`、`invalid`）。
- **协议层自检**：`abap run zcl_akit_mcp_selftest` 通过，覆盖
  - legacy：`initialize` / `ping` / `tools/list` / `tools/call`；
  - 通知 → `202`；
  - `-32700`（非法 JSON）、`-32600`（结构非法）、`-32022`（不支持的版本）；
  - modern：`server/discover` 的 `resultType` / `ttlMs` / `cacheScope` / `_meta.serverInfo`、modern `initialize` → `404 -32601`、头不匹配 → `400 -32020`；
  - modern 头镜像：`Mcp-Method` / `Mcp-Name` 与 body 的一致性校验。

## 4. 未验证项

以下项**没有真机证据**，首次部署请逐项确认：

| 项 | 风险 | 怎么确认 |
|---|---|---|
| 带 Basic 认证的 HTTP 端到端 | 测试系统只有 Basic 认证；`401` 只证明节点可达，未用真实账号跑完整 `curl` 链路 | 用你自己的 SAP 账号按 [protocol.md 第 8 节](protocol.md#8-验收-curl-序列) 跑一遍 curl 序列 |
| 8 个内置工具的真实数据调用 | 工具实现依赖各系统表/权限差异 | 逐个 `tools/call`，确认返回与 `isError` 行为 |
| MCP 客户端实际连接 | Claude Code / Cursor / VS Code 的版本与行为差异 | 各连一次，看走 legacy 还是 modern、`tools/list` 是否正常 |
| CORS 行为 | 不同 kernel 的 ICF 头处理差异 | 用浏览器/curl 带 `Origin` 验证 `403` 与预检 `204` |
| `ORIGINS` 配置生效 | 配置按 endpoint/`*` 查找 | 配一个白名单后验证预检与正常请求的 `Access-Control-Allow-Origin` |
| AFF 推送/激活（ECC EHP8） | 老系统 class builder 行为差异 | `abap push` 后 `abap inspect <obj> --activation` 检查全部绿色 |
| ICF 节点创建（ECC EHP8） | AFF HTTP 格式是否被接受 | `SICF` 检查 `/sap/bc/mcp` 存在且激活 |
| `/UI2/CL_JSON`（ECC EHP8） | 未装 SAP_UI 或版本过低 → 编译错误 | `SE24` 查 `/UI2/CL_JSON`；没有则先装 SAP_UI 7.40+ |
| DDIC 字段文本（中文） | `DD03T`/`DD04T` 语言相关，模型看到的参数说明可能为英文或空白 | `SE11` 看结构字段的 `@EndUserText.label`；必要时补中文文本 |
| 中文响应编码 | ICF 字符集设置 | `curl` 调 `sap_info` 看中文是否乱码；必要时在 ICF 配置里调字符集 |
| 权限检查 | ECC 与 S/4HANA 的授权对象字段差异 | 用受限账户逐个 tool 验证 `isError:true` 的授权失败消息 |
| TLS / SSO | 各系统 STRUST/SPNEGO 配置不同 | 按 [security.md](security.md) 的生产清单逐项确认 |

语法层面的保护：框架只用 **7.40 之后可用的经典构造**，不引入 RAP / ABAP Cloud 专有 API（见下节）。这降低了 ECC 上的语法风险，但不能替代真机验证。

## 5. 7.50 语法边界

框架与内置工具遵循「经典 ABAP」约束（`AGENTS.md` 的硬规则）：

**允许使用**

| 类别 | 示例 |
|---|---|
| 面向对象 | `CLASS` / `INTERFACES` / `CLASS-METHODS` / `IF_HTTP_EXTENSION` / `IF_OO_ADT_CLASSRUN` |
| 异常 | `TRY` / `CATCH cx_root` / `RAISE EXCEPTION TYPE` |
| 动态调用 | `CALL METHOD (class)=>(method)`、`CREATE DATA ... TYPE (struct_name)`、`ASSIGN` |
| 内联声明 | `DATA(...)`、`FIELD-SYMBOL(<...>)`、`VALUE #( )`、`CAST`、`CONV` |
| 字符串 | 字符串模板 `\|...\|`、`to_lower` / `to_upper` / `condense` / `strlen` |
| 内表 | `line_exists`、表表达式、`SELECT ... INTO TABLE`、`READ TABLE` |
| 反射 | `cl_abap_classdescr` / `cl_abap_typedescr` / `cl_abap_structdescr` / `cl_abap_elemdescr` / `cl_abap_tabledescr` |
| JSON | `/UI2/CL_JSON` |
| ICF | `IF_HTTP_SERVER` / `IF_HTTP_REQUEST` / `IF_HTTP_RESPONSE` / `set_session_stateful` |

**禁止使用**

| 禁止 | 原因 |
|---|---|
| RAP / ABAP Cloud 专有 API（behavior definition、XCO、`cl_abap_cloud*`） | 面向 ECC 常规开发，老系统没有这些 |
| `REDUCE` / `FOR` / `FILTER` / `FINAL(` / `REF #` / `CORRESPONDING #( )` | 7.40 基线不稳定，仓库约定不使用 |
| `*` 行注释、`FORM` / `PERFORM`、`START-OF-SELECTION` | 项目风格：全 OO，`"` 注释 |
| 中文/拼音标识符、ABAP 源码里的中文注释 | SAP 对象名与代码页限制；源码注释一律英文 |
| 用 `ZCX_*` 表达协议错误 | 协议错误是 JSON-RPC code，异常只表达 tool 业务失败 |
| SSE / 长连接 / session API | 本服务无状态，`set_session_stateful` 关闭 |
| 依赖 abapGit 的序列化格式 | 源码以 AFF 形式进 Git，由 abap-cli 推送 |

## 6. 版本与升级

- **本服务版本**：`ZCL_AKIT_MCP_TYPES=>GC_VERSION = '1.0.0'`，出现在 `serverInfo.version` 与响应头 `X-Akit-Mcp-Version`。
- **协议版本**：见 [protocol.md](protocol.md)；新增 era 或方法属于 breaking change，需在 CHANGELOG 的 `Changed` 里写升级动作。
- **表结构变化**：升级时按 CHANGELOG 的升级动作重新 `abap push` 对应表对象，再重跑 `abap run zcl_akit_mcp_setup`（幂等，不覆盖已有注册行）。
- **AFF `formatVersion`**：当前所有 AFF JSON 为 `"1"`；abap-cli 升级若要求更高 formatVersion，按工具提示迁移，`npm run check:aff` 会校验每个 JSON 都有该字段。
