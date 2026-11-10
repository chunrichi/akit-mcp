# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/)；版本号遵循 [Semantic Versioning](https://semver.org/)。
`Added` / `Changed` / `Removed` / `Fixed` / `Security` 按版本分组；breaking 变更在 `Removed` 标记并附 **Migration**。
条目面向使用者：写「能做什么 / 行为如何变化 / 升级要做什么」，不写内部实现；同一功能的细节合并成一条。
`[Unreleased]` 段永远保留且默认为空，下次发布的条目先写在这里。

## [Unreleased]

## [1.0.0] - 2026-11-10

首个公开版本：一个 ICF 节点、8 个只读内置工具、幂等安装器与中英双语文档。

### Added

- **MCP Server**：ABAP 实现的无状态 MCP over Streamable HTTP，装在 SAP 内部；ICF 节点 `/sap/bc/mcp`，对外 URL `/sap/bc/mcp/<endpoint>`，POST-only，无 SSE、无 session。
- **双 era 协议**：legacy（`2025-03-26` / `2025-06-18` / `2025-11-25`，统一按 `2025-11-25` 形状回复）与 modern（`2026-07-28`：`server/discover`、每请求 `_meta`、`Mcp-Method`/`Mcp-Name` 头镜像、`resultType`/`ttlMs`/`cacheScope` 信封）。
- **多 endpoint**：注册表 `ZTAKIT_MCP_TOOL` 的 `SERVER` 决定 endpoint 与工具集；配置表 `ZTAKIT_MCP_CONF` 按 endpoint 配置、`*` 为全局默认；根路径返回 endpoint 目录。
- **一行注册工具**：tool 类实现 `GET_META` + `EXECUTE`，入参走 DDIC 结构；框架自动把结构转成 JSON Schema（字段名、类型、`@EndUserText.label` / 数据元素文本），并完成参数反序列化与动态 `CALL METHOD`。
- **8 个内置只读工具**：`sap_info`、`object_search`、`source_read`、`syntax_check`、`ddic_get`、`table_read`、`tcode_info`、`message_text`。
- **配置项**：`ENABLED`（总开关）、`READ_ONLY`（默认只读）、`MAX_ROWS`（默认 200，硬顶 5000）、`ORIGINS`（CORS 白名单）、`INSTRUCTIONS`、`TITLE`。
- **安装与自检**：AFF 源码进 Git + `abap-cli` 部署；`node scripts/install.mjs` 幂等创建/推送/激活对象与 ICF 节点；`abap run zcl_akit_mcp_setup` 幂等播种内置工具并输出自检报告；`abap run zcl_akit_mcp_selftest` 校验协议分发与错误码；`scripts/akit-mcp.mjs` 本地客户端调试。
- **文档与 CI**：中英 README、协议/工具/写工具/安全/兼容性/排障文档、AFF 与文档链接校验脚本、GitHub Actions `verify`。

### Changed

- **协议数据形状**：legacy 三个版本统一用 `2025-11-25` 的线格式，旧客户端忽略未知字段；modern 结果统一带 `resultType` 与 `_meta["io.modelcontextprotocol/serverInfo"]`。
- **表字段命名**：注册表用 `SERVER` / `TOOL_CLASS` / `TOOL_ENABLED` / `TOOL_SORT`；配置表用 `SERVER` / `CONF_NAME` / `CONF_VALUE`，每行按 endpoint 生效。

### Limitations

- 无 SSE、无服务端通知、无会话（`Mcp-Session-Id` 不发也不回显）；不加 tool 后客户端需重连才能看到（无 `listChanged`）。
- 不支持 `resources` / `prompts` / `tasks` / `sampling` / `elicitation` / `logging`；能力只声明 `tools`。
- v1 不提供写工具：框架支持 `write` 标记与 `READ_ONLY` 开关，但内置工具全部只读。
- 认证依赖 ICF 登录（Basic / SSO），未实现 OAuth；OAuth-only 客户端需前置网关。
- 参数 `required` 只体现在 JSON Schema；服务端不做框架级必填校验，由各工具实现自行校验。
- 依赖 `/UI2/CL_JSON`（SAP_UI 7.40+）。
- ECC 未真机验证；S/4HANA 已验证。详见 [docs/compatibility.md](docs/compatibility.md)。
