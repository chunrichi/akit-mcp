# 安全

> 把 SAP 内部能力暴露给 AI 客户端，安全边界必须说清楚：**认证靠 ICF，鉴权靠 SAP 标准权限，服务本身只做最小暴露面**。
> 本文写「已经做了什么 / 生产上还要做什么 / 明确没做什么」。

## 1. 认证：复用 ICF 登录，不做匿名访问

- MCP 请求走 ICF 节点 `/sap/bc/mcp`，先经过 SAP 标准登录过程，再进入 `ZCL_AKIT_MCP_HTTP`。
- 支持 ICF 登录过程能提供的所有方式：**HTTP Basic**、**SSO（SAP Logon Ticket / SPNEGO，取决于系统配置）**。
- **不支持匿名**：不要在 ICF 节点上挂匿名登录过程，也不要把服务暴露到公网。
- **未实现 OAuth 2.0 / OIDC**：MCP 规范里的 OAuth 授权流程不在 v1 范围内。OAuth-only 的客户端（例如 ChatGPT 自定义 connector）前面需要 API Gateway 或 OAuth 代理。
- 调用者身份 = SAP 用户本人。工具的 `AUTHORITY-CHECK`、`sap_info` 返回的用户名、`sy-uname` 都指向真实调用者，不做服务账号代理。

```bash
# Basic 认证等价于每个请求都带 ICF 登录票据
curl -u <user>:<password> https://<host>:<port>/sap/bc/mcp/dev ...
```

## 2. 鉴权：标准 authorization object，不做自定义权限对象

框架**不引入自己的授权对象**（避免 SU21/角色安装成本），每个工具在 `EXECUTE` 里用 SAP 标准权限检查：

| 内置工具 | 典型授权检查 |
|---|---|
| `sap_info` | 登录即可 |
| `object_search` | `S_DEVELOP`，`ACTVT = 03` |
| `source_read` | `S_DEVELOP`，`ACTVT = 03` |
| `syntax_check` | `S_DEVELOP`，`ACTVT = 03` |
| `ddic_get` | `S_DEVELOP`，`ACTVT = 03` |
| `table_read` | `S_TABU_NAM`，`ACTVT = 03`，`TABLE = <表名>` |
| `tcode_info` | 登录即可 |
| `message_text` | 登录即可 |

规则：

- 权限检查在 **tool 实现内**完成，失败抛 `ZCX_AKIT_MCP_TOOL_ERROR`，对外是 `isError:true` 的普通业务错误，不泄露内部对象名以外的信息。
- 框架只做通用兜底（缺 `name`、未知 tool、参数不是对象），**不替工具做权限判断**——新增自定义 tool 时，作者必须自己写 `AUTHORITY-CHECK`。
- 你的自定义 tool 应该选**已有业务权限对象**做检查，而不是自建 Z 对象；这样角色/权限沿用现有体系，不需要额外的安全评审。
- 上表是 v1 内置工具的实现；新增 tool 的权限检查由作者自己决定，缺权限时抛 `ZCX_AKIT_MCP_TOOL_ERROR`（不要抛 `CX_SY_*` 原文）。

## 3. 只读默认

- 配置项 `READ_ONLY` 默认为 `X`：`write = true` 的工具**既不出现在 `tools/list`，也不能被 `tools/call` 调用**（调用返回「未知 tool」，不暴露其存在）。
- v1 的 8 个内置工具全部只读，不会修改 SAP 数据或开发对象。
- 要开放写工具，必须在配置表里显式把对应 endpoint 的 `READ_ONLY` 置空/非 `X`，并重新评估该 endpoint 的权限与暴露范围。**不要**在一个 endpoint 上同时放只读与高风险写工具。
- 写 SAP 开发对象的操作（建类、改源码、激活、传输）**不属于本服务**：由 `abap-cli` 在受控的开发者环境里执行。MCP 服务只暴露运行期能力。

## 4. 多 endpoint 隔离

一个 ICF 节点下可以有多个 endpoint（URL 段），每个 endpoint 有自己的工具集与配置：

| 对象 | 隔离粒度 |
|---|---|
| 工具集 | `ZTAKIT_MCP_TOOL.SERVER`（endpoint 名） |
| 配置 | `ZTAKIT_MCP_CONF.SERVER`，`*` 为全局默认值，endpoint 行优先 |
| 开关 | `ENABLED`（整个 endpoint）、`READ_ONLY`、`MAX_ROWS`、`ORIGINS`、`TITLE`、`INSTRUCTIONS` |

推荐用法：按受众拆 endpoint，例如

- `dev`：开发者用，只读开发工具 + 少量查询；
- `ops`：只放运维查询（`table_read` + 白名单表）；
- `biz`：只放业务查询 tool。

注意：**endpoint 是暴露面管理工具，不是强安全边界**。所有 endpoint 共享同一个 ICF 节点、同一个处理器类、同一个 SAP 用户权限模型；真正的边界是「该 SAP 用户有没有对应权限」。不要把敏感工具和公开工具放在同一个用户可访问的 endpoint 上就以为隔离了。

停用某个 endpoint：把它的 `ENABLED` 置为空（收到请求返回 `503`），或删除注册表/配置行（endpoint 不存在 → `404`）。

## 5. CORS（浏览器场景）

- 配置项 `ORIGINS`：逗号分隔的白名单，大小写不敏感。
- **为空 = 拒绝所有带 `Origin` 的浏览器请求**（`403`）。curl、桌面客户端、服务间调用通常不带 `Origin`，不受影响。
- 只有来自白名单 Origin 的请求才会得到 `Access-Control-Allow-*` 响应头；`OPTIONS` 预检返回 `204`。
- 生产上如果没有任何浏览器客户端，保持 `ORIGINS` 为空是最省心的配置；如果要从 Web 应用调用，把**完整 origin**（`https://app.example.com`）加进去，不要用 `*`。

CORS 是工程补充，不是 MCP 协议要求；它只影响浏览器，不构成认证或鉴权。

## 6. 暴露面与资源限制

- 能读到的东西：系统标识、开发对象清单与源码、DDIC 元数据、透明表/视图数据、事务码信息、消息文本。**都是调用者本身有权限读到的内容**，不额外放大权限。
- `MAX_ROWS`（默认 200，硬上限 5000）限制查询类工具返回行数。
- `source_read` 有行数上限（`max_lines` 参数，框架侧再限一次）；`table_read` 只接受透明表/视图，字段名会校验，条件只支持白名单操作符。
- 请求体上限 1 MB（`gc_max_body_chars`），超出返回 `400`。
- 无状态：不保存任何请求数据、不建会话、不写日志表。服务端不落调用记录（审计需求见第 8 节）。
- `sap_info` 只返回系统 ID/客户端/用户/版本/DB/主机/语言/时间，不返回连接串、密码、RFC destination 等敏感信息。

## 7. 生产部署清单

部署到生产前逐项确认：

- [ ] **TLS**：ICF 只走 HTTPS；证书在 `STRUST` 里维护，HTTP 端口对外关闭。
- [ ] **认证**：ICF 节点使用非匿名的登录过程（Basic 或 SSO）；禁止匿名。
- [ ] **权限**：调用账户的角色只包含需要的 `S_DEVELOP` / `S_TABU_NAM` / `S_TABU_DIS` 等权限；不要用 `SAP_ALL` 账户跑 MCP。
- [ ] **只读**：确认所有对外 endpoint 的 `READ_ONLY` 仍为 `X`；v1 不开放写工具。
- [ ] **endpoint 规划**：按受众拆分，生产只注册必要工具；`dev` 类 endpoint 不要在生产注册。
- [ ] **CORS**：`ORIGINS` 为空（无浏览器客户端）或只列真实前端 origin。
- [ ] **行数上限**：按数据敏感度调低 `MAX_ROWS`（例如 50），不要依赖 5000 硬顶。
- [ ] **网络**：ICF 节点只对内网/VPN/API Gateway 暴露；公网入口必须在网关做认证与限流。
- [ ] **安装方式**：对象落在自有包 + transport request（不要 `$TMP`）；安装后 `abap run zcl_akit_mcp_setup` 自检通过。
- [ ] **传输**：`abap-cli` 连接使用专用 profile，不要提交 `.abap.json` / 密码 / 主机名。
- [ ] **监控**：用 `SMICM` / ICF 统计观察调用量与错误率；异常排查用 `ST22`（本服务不写应用日志表）。

## 8. 明确没做的防护

以下能力**当前不提供**，部署时需在网关或流程层补：

| 未做 | 风险 | 建议 |
|---|---|---|
| OAuth / OIDC 授权服务器 | OAuth-only 客户端无法直连 | 前置 API Gateway 做 OAuth 代理 |
| 限流 / 配额 | 单用户可刷爆 SAP 工作进程 | ICF/SMICM 限制并发，网关限流 |
| IP 白名单 | 任何能访问 ICF 的主机都可尝试登录 | 防火墙/网关白名单 |
| 字段级脱敏 | 有权限的表数据会被原样返回 | 用权限控制到表/字段，或写专用只读视图工具 |
| 调用审计日志 | 无应用层「谁在何时调了什么」记录 | 用 ICF/SM21 日志或网关审计；v1.1 计划 BAL 日志 |
| 请求内容审计 / DLP | 敏感条件值可能出现在 URL/body 中 | 网关做 TLS 终止与审计 |
| 防重放 | Basic 认证本身无重放保护 | TLS + 网关策略 |
| SSE/长任务隔离 | 不存在（无 SSE） | — |

漏洞报告方式与责任边界见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
