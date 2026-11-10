# 项目要求

**把 SAP 里的普通 ABAP 方法变成 MCP tool。**

> 本文件是本仓库的 repo-level 合约。改动框架/tool 契约先改 `docs/design.md`。

## 规则

- 面向 **ECC / 常规 ABAP 开发**：只用 SAP_BASIS 7.40 可用的经典 API；不引入 RAP / ABAP Cloud 专有 API。
- 面向 **LM Agent 使用**：tool 描述与参数 schema 是产品的一部分；新增/改 tool 必须同时考虑模型能否选对、参数能否填对。
- 面向 **维护者**：加一个 tool = 一个类 + 一个 DDIC 入参结构 + 注册表一行；框架不写 JSON、不写 schema 代码。
- 一切 SAP 对象以 **AFF 源码** 形式进 Git（`abap/src/`），用 `abap-cli` 推送与激活；不依赖 abapGit。
- 文档不写内部编号（issue / PR / spec 编号），结论沉淀进 `docs/` 或本文件。

## 架构（三层）

- **传输层**（`ZCL_AKIT_MCP_HTTP`）：`IF_HTTP_EXTENSION`，只做 HTTP 与方法门禁，不解析 MCP。
- **协议层**（`ZCL_AKIT_MCP_SERVER` + `ZCL_AKIT_MCP_JSON`）：JSON-RPC 2.0、legacy / modern 两个 era、方法分发、错误码、信封。
- **工具层**（`ZCL_AKIT_MCP_TOOLS` + `ZCL_AKIT_MCP_TOOL_*`）：注册表、`GET_META` / `EXECUTE` 契约、DDIC → JSON Schema、动态调用。
- **配置/安装**（`ZCL_AKIT_MCP_CONFIG` / `ZCL_AKIT_MCP_SETUP` / `ZCL_AKIT_MCP_SELFTEST`）：键值配置（按 endpoint）、内置 tool 幂等播种与自检、无 HTTP 协议回归。

## 关键约定

- 命名：`ZCL_AKIT_MCP_*` / `ZCX_AKIT_MCP_*` / `ZTAKIT_MCP_*`（表）/ `ZSAKIT_MCP_*`（结构）/ `ZAKIT_MCP_*`（节点、程序）。类名 ≤ 30 字符。
- 多 endpoint：ICF 节点 `/sap/bc/mcp`，对外 `/sap/bc/mcp/<endpoint>`；注册表 `ZTAKIT_MCP_TOOL` 的 `SERVER` 字段即 endpoint；配置表 `ZTAKIT_MCP_CONF` 按 endpoint 生效，`SERVER='*'` 为全局缺省。
- tool 类固定两个方法：`GET_META`（元数据）+ `EXECUTE`（实现），全部 `PUBLIC` / `CLASS-METHODS`；不可实例化也必须有 `FINAL CREATE PUBLIC`。
- 入参一律走 DDIC 结构（`args_struct`），字段名即 MCP 参数名（JSON 侧 camelCase）；DDIC 字段用 `@EndUserText.label` 写中文描述（通用类型字段必须写 label）。数组/嵌套对象/自定义 schema 用 `raw_args` 模式。
- `inputSchema` 默认由 DDIC 结构自动生成；确有不适合自动生成的部分时，工具类可实现可选方法 `GET_SCHEMA` 返回 `ty_tool_schema`（`A` AUTO / `M` MANUAL / `N` NONE），缺省或异常回退 AUTO。它只影响 schema，不影响参数绑定。
- 鉴权、必填校验、行数上限在 tool 内完成；框架只做 required → `inputSchema` 的投影与异常兜底（不做框架级必填强制）。
- 认证复用 ICF 登录；鉴权用标准 authorization object（内置工具：S_DEVELOP 03 / S_TABU_NAM 03，其余登录即可）。
- 返回 `string`（JSON 文本）：正常结果是业务数据；错误抛 `ZCX_AKIT_MCP_TOOL_ERROR`。
- 框架不信任 tool：所有动态调用放在 `TRY / CATCH cx_root` 内，单个 tool 失败不能影响其它 tool 与 `tools/list`。
- 源码文件命名遵循 AFF 扁平布局：`<name>.<type>[.<sub_type>].<ext>`，小写。

## 验证

- 回归测试：`abap run zcl_akit_mcp_selftest`（协议分发 + 8 个内置工具的最小调用，不经过 ICF；输出 JSON 行）；ABAP Unit 为可选补充。
- 真机：S/4HANA（profile `test`）上 `node scripts/install.mjs` → `abap run zcl_akit_mcp_selftest`；带账号的端到端用 `node scripts/akit-mcp.mjs --url .../sap/bc/mcp/dev --user <u> tools`（HTTP 层需 ICF 登录，测试系统只做 401 探测）。
- ECC 无测试系统：只用 7.40 经典 API；改动涉及新 API 时在 `docs/compatibility.md` 标注最低版本。
- 提交前：`npm run verify`（AFF 校验 + 文档链接检查 + 本地脚本自检）。

## 文档

- `README.md` / `README.zh-CN.md`：定位、安装、连接客户端、写第一个 tool。
- `docs/design.md`：设计契约（本文件之上）。
- `docs/protocol.md`：实现的 MCP 方法/版本/错误码矩阵。
- `docs/tools.md`：内置 tool 参考（参数、返回、授权）。
- `docs/writing-a-tool.md`：tool 开发指南（含 DDIC 结构、注册、调试）。
- `docs/security.md`：认证、鉴权、部署边界、生产清单。
- `docs/troubleshooting.md`：症状 → 原因 → 处理。
- `docs/verification.md`：真机验证记录（环境、部署、协议回归、工具冒烟、未验证项）。
