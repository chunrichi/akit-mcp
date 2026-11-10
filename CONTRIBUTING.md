# 贡献指南

> 本仓库的硬规则在 [AGENTS.md](AGENTS.md)：改框架/tool 契约先改 [docs/design.md](docs/design.md)，再改代码与文档。
> 参与贡献即表示同意以 MIT 许可发布你的贡献。

## 1. 开始之前

1. 读 [AGENTS.md](AGENTS.md)（仓库合约）与 [docs/design.md](docs/design.md)（设计契约）。两者与本文冲突时，以 AGENTS.md 为准。
2. 本地需要 Node.js >= 20；需要 SAP 的步骤只在最后真机验证时执行。
3. 不要提交真实主机名、SAP 用户/密码、`.abap.json`、transport 号、dump 内容或客户数据。

## 2. 提交信息：Conventional Commits

一条提交只做一件事。格式：

```text
<type>(<scope>): <subject>
```

- `type`：`feat` / `fix` / `docs` / `chore` / `refactor` / `test` / `perf` / `ci`。
- `scope`：`mcp`（协议/传输）、`json`（解析器）、`tools`（注册表与内置工具）、`tool-<name>`、`setup`（安装与播种）、`docs`、`ci`、`deps`、`release`。
- `subject`：**英文祈使句**，全小写开头，不加句号，**≤ 72 字符**；不加 emoji、不加 issue/PR/需求编号。
- body（可选）：写 why、影响面、验证方式；同样不写编号。
- breaking：`feat(mcp)!: ...` 或在 footer 写 `BREAKING CHANGE: ...`，并同步 CHANGELOG 的 `Removed` 与 **Migration**。

示例：

```text
feat(tools): register the eight read-only built-in tools
fix(json): reject a bare surrogate pair in \u escapes
docs(writing-a-tool): show the DDIC structure step end to end
refactor(server): move era detection behind one predicate
feat(mcp)!: drop the legacy 2024-11-05 handshake
```

## 3. 分支与 Pull Request

- 分支名：`feat|fix|docs|chore|refactor/<kebab-case-slug>`，从 `main` 拉出，短生命周期。
- 一个 PR = 一个可评审的交付单元；PR 标题 = squash 后的 commit subject。
- 不直推 `main`，不 force push `main`，不绕过 required check。
- PR 描述写：改了什么、为什么、怎么验证（贴 `npm run verify` 结果；涉及 SAP 的贴真机证据摘要，隐去敏感信息）。
- 合并后删除分支。

## 4. 文档语言与风格

| 位置 | 语言 | 说明 |
|---|---|---|
| `README.md` / `README.zh-CN.md` | 英文 / 中文 | 两份**同结构、同章节数**；中文版是全文对照，不是摘要 |
| `docs/*.md` | 中文 | 对外/对贡献者的稳定文档；每篇单一主题，H2 ≤ 8 |
| `AGENTS.md` | 中文 | 仓库合约 |
| `CHANGELOG.md` | 中文前言 + 英文分组标题 | Keep a Changelog |

- ABAP 源码与注释、commit message、代码标识符一律**英文**；DDIC 字段文本（`@EndUserText.label`）与 MCP `title`/`description` 用**中文**（给模型/用户看）。
- 文档不写内部编号（issue / PR / spec / 需求号），结论沉淀到 `docs/`。
- 命令、URL、对象名、错误码必须与实现一致；没验证过的状态要标注「未验证」，不要写成「已支持」。
- 表格优先、少用长段落；README 的每个能力都要落到一个可执行动作（命令 / MCP 方法 / 一行注册）。
- `docs/research/` 是一次性调研稿，不是对外文档；结论进 `docs/design.md` 与 `AGENTS.md` 后不要长期双写。

## 5. 本地校验（不连 SAP）

提交前必须让一个闸门变绿：

```bash
npm run verify
```

它由两个检查组成：

| 命令 | 检查内容 |
|---|---|
| `npm run check:aff` | `abap/src` 的结构与命名：JSON 可解析且有 `formatVersion`、`.clas.abap` 以 `CLASS` 开头、表/结构两件套齐全、文件名 `<token>.<type>[.<sub>].<ext>` 且全小写、ICF 定义含 handlerClass/servicePath |
| `npm run check:docs` | 必需文档存在、README/docs 的相对链接与图片路径可达、中英 README 章节结构一致、许可证一致 |

CI（GitHub Actions，node 20）跑同一条命令；CI 上**没有 SAP**，任何依赖 SAP 的步骤都不能进 `verify`。

## 6. SAP 真机验证要求

以下改动必须真机验证后才能合并（在 PR 里贴结果）：

- 协议/传输层（`ZCL_AKIT_MCP_HTTP` / `ZCL_AKIT_MCP_SERVER`）：`initialize` → `notifications/initialized` → `tools/list` → `tools/call` 全链路，legacy 与 modern 各一遍。
- 表结构/配置（`ZTAKIT_MCP_TOOL` / `ZTAKIT_MCP_CONF`）：升级路径（`abap push` + 重跑 `abap run zcl_akit_mcp_setup`）与旧数据兼容。
- 新增/修改 tool：至少一次真实 `tools/call` 成功 + 一次 `isError:true` 失败样例（缺参数或权限不足）。
- 安装链（`scripts/install.mjs` / ICF 节点）：在干净系统上从零跑通。

真机验证的最小链路：

```bash
abap init --profile <profile> --package '$TMP'   # from the repository root
node scripts/install.mjs                          # create/push/activate + seed
abap run zcl_akit_mcp_selftest
node scripts/akit-mcp.mjs --url https://<host>:<port>/sap/bc/mcp/dev --user <u> --password <p> tools
```

- 真机对象（profile、凭证、dump）不提交；证据以脱敏后的输出摘要贴进 PR。
- **ECC 没有测试系统**：只用 SAP_BASIS 7.40+ 的经典 API；涉及新 API/新语法时在 `docs/compatibility.md` 标注最低版本，并在 PR 里说明「ECC 未验证」。
- ABAP Unit：新增/修改框架类时补本地测试类，用 `abap test` 执行；单个 tool 至少一个只读冒烟用例。

## 7. 报告问题

- Bug/功能请求用 GitHub Issue：写清 SAP 版本与组件（SAP_BASIS / SAP_UI）、`SICF` 节点状态、最小复现请求/响应、`abap run zcl_akit_mcp_setup` 输出（脱敏）。
- **安全漏洞不要开公开 issue**：先用仓库维护者公布的私密渠道联系，附影响范围与复现步骤；修复发布后再公开讨论。
- 提交前自查：没有凭证、没有真实主机名、没有客户数据、没有内部编号。

## 8. 许可

本项目使用 MIT 许可证（见 [LICENSE](LICENSE)）。提交 PR 即表示你同意以 MIT 许可发布贡献内容。
