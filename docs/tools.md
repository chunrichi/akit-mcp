# 内置工具参考

> v1 提供 8 个只读工具，由 `ZCL_AKIT_MCP_SETUP` 播种到默认 endpoint `dev`。
> 所有工具都通过 `tools/call` 调用；业务失败返回 `isError:true`（HTTP 仍是 `200`）。
> 协议层细节见 [protocol.md](protocol.md)；授权与部署边界见 [security.md](security.md)。

## 通用约定

- **endpoint**：内置工具注册在 `dev`，请求 URL 是 `/sap/bc/mcp/dev`。
- **参数名**：DDIC 字段名转 camelCase，例如 `OBJECT_TYPE` → `objectType`、`PACKAGE_NAME` → `packageName`。
- **返回**：`content[0].text` 是工具返回的 JSON 文本；顶层是 JSON 对象时还会给同源的 `structuredContent`。各工具的 `title` / `description` 就是模型在 `tools/list` 里看到的产品文案，下文逐字引用。
- **行数上限**：查询类工具先取 endpoint 的 `MAX_ROWS`（默认 200，`ZTAKIT_MCP_CONF` 可调），工具内部再压到**硬上限 500**；`maxRows` 参数只能调低、不能调高（`0`/缺省 = 用 endpoint 配置）。
- **校验在工具内**：`required` 只体现在 `inputSchema`，服务端不做框架级必填校验；缺参数/参数非法会返回 `isError:true` 的中文消息。
- **只读**：8 个工具都不修改 SAP 数据或开发对象。

## 工具总览

| Tool | 用途 | 授权检查 | 主要限制 |
|---|---|---|---|
| [`sap_info`](#sap_info) | 系统信息 | 登录即可 | 无 |
| [`object_search`](#object_search) | 搜索仓库对象 | `S_DEVELOP` 03 | 行数硬顶 500 |
| [`source_read`](#source_read) | 读源码 | `S_DEVELOP` 03 | 仅 CLAS/INTF/PROG；最多 5000 行 |
| [`syntax_check`](#syntax_check) | 语法检查 | `S_DEVELOP` 03 | 不保存、不激活；最多 5000 行 |
| [`ddic_get`](#ddic_get) | DDIC 元数据 | `S_DEVELOP` 03 | TABL/VIEW/STRU/DTEL；字段最多 500 |
| [`table_read`](#table_read) | 读表/视图数据 | `S_TABU_NAM` 03 | 仅透明表/视图；单表；行数硬顶 500 |
| [`tcode_info`](#tcode_info) | 事务码信息 | 登录即可 | 仅已存在的事务码 |
| [`message_text`](#message_text) | T100 消息文本 | 登录即可 | 消息类/编号必须存在 |

## 工具参考

### sap_info

- **title**：`SAP 系统信息`
- **description**：返回当前 SAP 系统、客户端、登录用户、ABAP 版本、数据库、应用服务器、语言与日期时间。只读，无参数。
- **参数**：无（`arguments` 传 `{}`）。
- **授权**：登录即可。
- **返回**（JSON 对象，字段名 camelCase）：

| 字段 | 含义 |
|---|---|
| `systemId` | 系统 ID（`sy-sysid`） |
| `client` | 客户端（`sy-mandt`） |
| `user` | 登录用户（`sy-uname`） |
| `abapRelease` | ABAP 版本（`sy-saprl`） |
| `databaseSystem` | 数据库系统（`sy-dbsys`） |
| `applicationServer` | 应用服务器主机（`sy-host`） |
| `language` | 登录语言（`sy-langu`） |
| `date` / `time` | 服务器日期/时间（`sy-datum` / `sy-uzeit`） |
| `serverName` / `serverVersion` | `akit-mcp` / `1.0.0` |

- **限制**：不返回连接串、密码等敏感信息。

### object_search

- **title**：`对象搜索`
- **description**：按名称模式、对象类型和包搜索 TADIR 仓库对象，返回对象名、类型、包、作者、创建日期与描述。只读；最多返回配置上限行数（默认 200，硬上限 500）。
- **授权**：`S_DEVELOP`，`ACTVT = 03`。
- **参数**：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `pattern` | string（40） | ✅ | 对象名匹配模式：`*`/`?` 通配；**没有通配符时按前缀匹配** |
| `objectType` | string（4） | | 对象类型（`CLAS`/`INTF`/`PROG`/`TABL`…），空 = 全部 |
| `packageName` | string（30） | | 包名过滤，空 = 全部包 |
| `maxRows` | integer | | 最大返回行数；`0`/缺省 = endpoint 的 `MAX_ROWS`，只能调低 |

- **返回**：`{ objects: [...], count, truncated }`；`objects[]` 元素字段：

| 字段 | 含义 |
|---|---|
| `name` | 对象名 |
| `objectType` | TADIR 对象类型 |
| `package` | 包（`devclass`） |
| `author` | 作者 |
| `createdOn` | 创建日期 |
| `description` | 对象描述（按类型取类/程序/表/数据元素文本，当前语言缺失时回退英文；取不到为空） |

- **限制**：只搜 `TADIR` 中 `PGMID = 'R3TR'` 的仓库对象；模式为空报错；行数硬顶 500。

### source_read

- **title**：`读取 ABAP 源码`
- **description**：读取类/接口/报表程序的 active 版本源码（按行返回），支持行数上限。只读；FUGR 暂不支持。
- **授权**：`S_DEVELOP`，`ACTVT = 03`。
- **参数**：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `objectName` | string（40） | ✅ | 对象名（类/接口/报表程序） |
| `objectType` | string（4） | | `CLAS`/`INTF`/`PROG`；空 = 自动识别（CLAS → INTF → PROG） |
| `maxLines` | integer | | 最大返回行数；`0`/缺省 = 5000，只能调低 |

- **返回**：`{ objectName, objectType, lineCount, truncated, lines }`；`lines` 是字符串数组（每行一条）。`truncated = true` 表示源码超过 `maxLines` 被截断。
- **限制**：只读取 **active 版本**；CLAS/INTF 走 ADT 类源码接口（`CL_OO_FACTORY` / `IF_OO_CLIF_SOURCE_FACTORY`），PROG 走 `RPY_PROGRAM_READ`；函数组（FUGR）不支持，会报「不支持的对象类型」；不存在的对象报读取失败。

### syntax_check

- **title**：`ABAP 语法检查`
- **description**：对一段完整编译单元的 ABAP 源码做语法检查（不保存、不激活），返回是否通过、错误行号/单词/消息。上下文默认使用内置报表 `ZAKIT_MCP_SYNTAX_CONTEXT`。只读。
- **授权**：`S_DEVELOP`，`ACTVT = 03`。
- **参数**：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `source` | string | ✅ | 待检查的 ABAP 源码（换行分隔，作为完整编译单元） |
| `programName` | string（40） | | 语法检查上下文程序（必须是已存在的 `PROG`）；空 = 用 `ZAKIT_MCP_SYNTAX_CONTEXT` |

- **返回**：`{ valid, returnCode, line, word, message, lineCount, program }`；`valid = true` 表示语法通过，`returnCode` 是 `SYNTAX-CHECK` 的 `sy-subrc`，`line`/`word`/`message` 是第一条错误位置与文本。

```json
{ "valid": false, "returnCode": 4, "line": 3, "word": "ENDFOO",
  "message": "Statement ENDFOO is not recognized.", "lineCount": 12,
  "program": "ZAKIT_MCP_SYNTAX_CONTEXT" }
```

- **限制**：不保存、不激活、不生成对象；单次最多 5000 行，超出报错；上下文程序必须存在。

### ddic_get

- **title**：`DDIC 元数据`
- **description**：读取表/视图/结构/数据元素的 DDIC 元数据与字段清单（含字段文本）。只读；字段清单最多 500 条。
- **授权**：`S_DEVELOP`，`ACTVT = 03`。
- **参数**：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `objectName` | string（30） | ✅ | DDIC 对象名 |
| `objectType` | string（4） | | `TABL`/`VIEW`/`STRU`/`DTEL`；空 = 自动识别（先 `DD02L`，再 `DD04L`） |

- **返回**：`{ objectName, objectType, description, dataType, length, decimals, domain, fields, truncated }`。
  - TABL/VIEW/STRU：`fields[]` 每个元素含 `fieldName`、`position`、`keyField`、`dataType`、`length`、`decimals`、`dataElement`、`domain`、`description`；`truncated` 表示字段数超过上限被截断。字段描述优先取数据元素文本，其次取字段文本。
  - DTEL：`dataType`/`length`/`decimals`/`domain`/`description` 有值，`fields` 为空数组。
- **限制**：只支持 TABL/VIEW/STRU/DTEL（`DOMA` 等其它类型报「不支持的 DDIC 对象类型」）；字段清单最多 500 条（取 endpoint `MAX_ROWS` 与 500 的较小值）。

### table_read

- **title**：`表数据读取`
- **inputSchema**：该工具的 schema 由类里的可选方法 `GET_SCHEMA` 手工提供（MANUAL），以便给 `whereClause` 补 JSON 数组示例与 `minLength` 约束；参数绑定仍走 DDIC 结构 `ZSAKIT_MCP_TABLE_READ_ARGS`。
- **description**：对透明表或视图执行受限只读 SELECT，支持字段投影、JSON 过滤条件、单字段排序与行数上限。只读，不加锁、不写库；默认最多 200 行，硬上限 500。
- **授权**：`S_TABU_NAM`，`ACTVT = 03`，`TABLE = <表名>`。
- **参数**：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `tableName` | string（30） | ✅ | 透明表或视图名 |
| `fields` | string（255） | | 返回字段，逗号分隔；空 = 全部字段 |
| `whereClause` | string（1024） | | 过滤条件 JSON 数组；空 = 无条件 |
| `orderBy` | string（255） | | 单字段排序，可带 `ASC`/`DESC`（缺省 `ASC`）；字段必须在返回字段中 |
| `maxRows` | integer | | 最大返回行数；`0`/缺省 = endpoint 的 `MAX_ROWS`，只能调低 |

`whereClause` 是 JSON 数组，元素形如 `{"field":"WERKS","op":"EQ","value":"1000"}`：

```json
[
  { "field": "WERKS", "op": "EQ", "value": "1000" },
  { "field": "MATNR", "op": "LIKE", "value": "ZCL%" }
]
```

- `field` 必须是表的字段（大小写不敏感）；`op` 只支持 `EQ`/`NE`/`LT`/`LE`/`GT`/`GE`/`LIKE`。
- `LIKE` 的 `value` 按原样拼进 SQL，不会自动补 `%`。
- 数值类字段（`INT1/2/4/8`、`DEC`、`CURR`、`QUAN`、`FLTP`）的 `value` 不能为空，按数值拼接；其它字段按字符串加引号（内部单引号会转义）。
- `whereClause` 给了就必须是非空数组；每个条件必须有 `field` 与 `op`。

- **返回**：`{ tableName, rows, rowCount, truncated }`；`rows` 是行对象数组（字段名取表的 DDIC 字段名并转 camelCase，例如 `MATNR` → `matnr`）；`rowCount` 是实际返回行数；`truncated = true` 表示还有更多行被行数上限截断。
- **限制**：对象必须是 `TRANSP`（透明表）或 `VIEW`，其它 `TABCLASS` 直接报错；不做 `ORDER BY` 下推——如果给了 `orderBy`，只对**本次返回的窗口**排序（取数后再排序），跨页排序不稳定；不加锁、不写库。

### tcode_info

- **title**：`事务码信息`
- **description**：按事务码返回描述、入口程序与屏幕号。只读；登录即可调用。
- **授权**：登录即可。
- **参数**：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `tcode` | string（20） | ✅ | 事务码（如 `SE11`、`VA03`） |

- **返回**：`{ tcode, description, program, dynpro, programTitle }`；`dynpro` 是屏幕号，`programTitle` 是程序文本（取不到为空）。
- **限制**：事务码必须存在（`TSTC`），否则报「事务码 X 不存在」；文本取当前语言，缺失回退英文。

### message_text

- **title**：`T100 消息文本`
- **description**：按消息类与消息编号返回 T100 文本；`variables` 用 `|` 分隔，依次替换文本中的 `&` 占位符。只读；登录即可调用。
- **授权**：登录即可。
- **参数**：

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `msgClass` | string（20） | ✅ | 消息类（如 `00`、`ZV`） |
| `msgNo` | string（3） | ✅ | 消息编号 |
| `variables` | string（255） | | 消息变量，`|` 分隔，依次替换 `&` |

- **返回**：`{ messageClass, description, messageNumber, text }`；`description` 是消息类文本，`text` 是替换变量后的消息文本。
- **限制**：消息类（`T100A`）与消息（`T100`）必须存在；文本取当前语言，缺失回退英文；`variables` 按顺序替换文本中**第一个** `&`，空值/多余变量被跳过。

## 调用示例

```bash
U='https://<host>:<port>/sap/bc/mcp/dev'; A='-u <user>:<password>'

# 搜索 ZCL_AKIT_* 类
curl -s $A -X POST "$U" -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"object_search","arguments":{"pattern":"ZCL_AKIT_*","objectType":"CLAS","maxRows":50}}}'

# 读 T000 的客户端文本
curl -s $A -X POST "$U" -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"table_read","arguments":{"tableName":"T000","fields":"MANDT,MTEXT","maxRows":10}}}'
```

失败示例（缺参数 → `isError:true`，HTTP 仍是 `200`；消息文本来自工具实现）：

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [{ "type": "text", "text": "参数 table_name 不能为空。" }],
    "isError": true
  }
}
```

自己新增 tool 见 [writing-a-tool.md](writing-a-tool.md)。
