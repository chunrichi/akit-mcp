# 写一个 tool

> 一个 tool = **一个类**（`GET_META` + `EXECUTE`）+ **一个 DDIC 入参结构**（可选）+ **注册表一行**。
> 框架不要求你写 JSON、不要求你写 schema 代码；你只写 ABAP。
> 契约细节见 [design.md 第 4 节](design.md#4-tool-模型核心设计)，内置工具的实现见 [tools.md](tools.md)。

## 1. 三个组成部分

| 部分 | 位置 | 作用 |
|---|---|---|
| DDIC 入参结构 | SE11，命名 `ZSAKIT_MCP_TOOL_<NAME>_ARGS` | 字段名 = MCP 参数名（camelCase）；字段文本 = 参数描述；类型决定 JSON 类型 |
| tool 类 | `ZCL_AKIT_MCP_TOOL_<NAME>`（≤30 字符） | `GET_META` 返回元数据，`EXECUTE` 实现逻辑 |
| 注册表行 | `ZTAKIT_MCP_TOOL` | 把类挂到某个 endpoint，决定是否启用与排序 |

源码以 AFF 形式进 Git（`abap/src/`），文件名小写：`zcl_akit_mcp_tool_stock.clas.abap` + `.clas.json`；结构是 `zsakit_mcp_tool_stock_args.stru.ddic` + `.stru.json`。`npm run check:aff` 会校验这些文件结构。

## 2. 第 1 步：建 DDIC 入参结构

在 SE11 建结构，字段就是参数：

```text
ZSAKIT_MCP_TOOL_STOCK_ARGS
  MATERIAL   CHAR 18    @EndUserText.label: '物料号'
  PLANT      CHAR 4     @EndUserText.label: '工厂'
```

规则：

- **字段名用小写下划线**（`object_type`），框架自动转成 MCP 参数名 `objectType`。
- **字段文本用中文**：`@EndUserText.label`（DD03T）优先；没有就用数据元素的文本（DD04T）；都没有就用字段名（`object_type` → `object type`）。模型的参数选择完全依赖这些文本。
- **类型映射**（框架自动生成 JSON Schema，不支持 `enum`/`minimum`/`format` 等高级关键字）：

| DDIC 类型 | JSON Schema |
|---|---|
| `INT1/INT2/INT4/INT8` | `integer` |
| `PACKED` / `FLOAT` / `DECFLOAT16/34` | `number` |
| 其它标量（CHAR/STRING/NUMC/DATS/TIMS…） | `string` |
| 嵌套结构 | `object`（v1 不展开字段） |
| 内表 | `array` |
| 任意类型的对象引用 | 跳过该字段 |

- **必填**在 `GET_META` 的 `required` 里声明，**不在**结构里表达（DDIC 字段没有 optional 概念）。
- **数组/嵌套入参 v1 不走 DDIC**，用第 6 节的 `raw_args` 模式。
- DDIC 结构只放「简单扁平字段」；参数校验、默认值、上限都在 `EXECUTE` 里做。

## 3. 第 2 步：实现 `GET_META`

```abap
CLASS zcl_akit_mcp_tool_stock DEFINITION
  PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_tool_stock_args
      RETURNING VALUE(rv_result) TYPE string.
ENDCLASS.

CLASS zcl_akit_mcp_tool_stock IMPLEMENTATION.
  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'stock_check'
      title       = '库存查询'
      description = '按物料与工厂查询非限制库存，只读，最多返回配置的 MAX_ROWS 行。'
      args_struct = 'ZSAKIT_MCP_TOOL_STOCK_ARGS'
      required    = VALUE #( ( `MATERIAL` ) ( `PLANT` ) ) ).
  ENDMETHOD.

  METHOD execute.
    " 实现见第 4 步
  ENDMETHOD.
ENDCLASS.
```

`ZCL_AKIT_MCP_TYPES=>TY_TOOL_META` 字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | `string` | MCP tool 名，**小写 snake_case**，在 endpoint 内唯一；框架会转小写并拒绝空名 |
| `title` | `string` | 展示名（中文） |
| `description` | `string` | 给模型看的用途与边界（中文，一两句） |
| `args_struct` | `string` | DDIC 结构名（大写）；无参工具留空 |
| `required` | `ty_strings` | 必填字段名（DDIC 字段名大写），框架转成 camelCase 写进 schema |
| `write` | `abap_bool` | `abap_true` = 写操作；`READ_ONLY = X` 时该工具被隐藏并拒绝 |
| `raw_args` | `abap_bool` | `abap_true` = 自定义入参模式（第 6 节） |
| `raw_schema` | `string` | raw 模式的 `inputSchema` JSON；非 raw 模式留空 |

`GET_META` 会被反复动态调用，必须**纯读取、无副作用、不依赖当前用户状态**（`tools/list` 每次都重新调用它）。

实现约束（否则工具会被静默跳过）：

- tool 类必须是**全局类**且已在 `TADIR` 注册（框架先查 `TADIR` 的 `RTR CLAS` 记录，避免动态调用不存在的类导致不可捕获的运行时错误）。本地类、包含程序里的局部类不行。
- `GET_META` 必须是无参数的静态方法；`EXECUTE` 的签名必须与第 4 步一致，否则该工具从 `tools/list` 消失。
- `args_struct` 指向的结构必须存在于 `DD03L`；不存在时 schema 退化为空 `properties`（工具仍会列出，但模型填不了参数），`zcl_akit_mcp_setup` 的 `invalid[]` 会报出来。

## 4. 第 3 步：实现 `EXECUTE`

```abap
  METHOD execute.
    AUTHORITY-CHECK OBJECT 'S_DEVELOP'
      ID 'ACTVT' FIELD '03'
      ID 'DEVCLASS' DUMMY ID 'OBJNAME' DUMMY ID 'OBJTYPE' DUMMY ID 'P_GROUP' DUMMY.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少 S_DEVELOP 显示权限（ACTVT=03）。'.
    ENDIF.

    IF is_args-material IS INITIAL OR is_args-plant IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = 'material 与 plant 均为必填参数。'.
    ENDIF.

    DATA(lv_max_rows) = zcl_akit_mcp_config=>max_rows_current( ).

    SELECT matnr, werks, labst, meins FROM mard
      INTO TABLE @DATA(lt_rows)
      WHERE matnr = @is_args-material
        AND werks = @is_args-plant
      UP TO lv_max_rows ROWS.

    rv_result = zcl_akit_mcp_json=>to_json( lt_rows ).
  ENDMETHOD.
```

契约：

- **入参**：正常模式 `IMPORTING is_args TYPE <args_struct>`；框架把 `params.arguments` 反序列化成结构后动态调用。字段名按 camelCase 映射。
- **必填校验在工具里做**：`required` 只写进 `inputSchema` 给模型看，服务端**不做**框架级必填校验——`EXECUTE` 里必须自己判断空值并抛 `ZCX_AKIT_MCP_TOOL_ERROR`（否则模型可能带着空参数调用）。同理，schema 里的 `additionalProperties:false` 只是提示，服务端不拒绝未知参数。
- **返回**：`RETURNING VALUE(rv_result) TYPE string`，内容是 JSON 文本。用 `zcl_akit_mcp_json=>to_json( ... )` 一行序列化（省略初始值，紧凑）。如果希望结果字段形状稳定（`false` / `0` / 空数组也输出，便于模型和客户端消费），改用 `zcl_akit_mcp_json=>to_json_full( ... )`——8 个内置工具都用它。返回 JSON **对象**时框架额外给 `structuredContent`；返回数组/标量只有 `content[].text`。
- **业务错误**：抛 `ZCX_AKIT_MCP_TOOL_ERROR`（`iv_details` 是人类/模型可读的中文消息，`iv_code` 可选，默认 `TOOL_ERROR`）→ `isError:true`。其它 `CX_ROOT` 也会被兜住并转成 `isError:true`，但消息可能不可读，**不要依赖它**。
- **鉴权**：`AUTHORITY-CHECK` 在 tool 内做，用标准授权对象；失败抛 `ZCX_AKIT_MCP_TOOL_ERROR`。框架不做权限判断。
- **限额**：查询类工具从 `ZCL_AKIT_MCP_CONFIG=>MAX_ROWS_CURRENT( )` 取当前 endpoint 的行数上限（默认 200，硬顶 5000），工具内再按业务需要收紧。
- **无副作用**：v1 的内置工具全部只读；写工具必须设 `write = abap_true`，由 `READ_ONLY` 开关控制暴露。

## 5. 第 4 步：注册、部署、验证

**注册一行**（SE16N/SM30 可维护 `ZTAKIT_MCP_TOOL`，表标注了 `dataMaintenance: ALLOWED`）：

| 字段 | 值 |
|---|---|
| `SERVER` | endpoint 名，小写（内置工具是 `dev`） |
| `TOOL_CLASS` | `ZCL_AKIT_MCP_TOOL_STOCK` |
| `TOOL_ENABLED` | `X` |
| `TOOL_SORT` | 排序号，越小越靠前（内置工具用 10–80） |

**推送与激活**（AFF 源码进 Git 后）：

```bash
# 推送（push 默认带激活）；STRU/TABL 推 main JSON，同目录的两件套一起带上。
# $TMP 免传输；非本地包要带 --tr <请求>。
abap push abap/src/zcl_akit_mcp_tool_stock.clas.abap
abap push abap/src/zsakit_mcp_tool_stock_args.stru.json

# 若 push 报 activated 但实际未激活
abap activate ZCL_AKIT_MCP_TOOL_STOCK ZSAKIT_MCP_TOOL_STOCK_ARGS --yes

# 自检：列出注册行的校验结果（含 invalid[]）
abap run zcl_akit_mcp_setup

# 新增多个对象时也可以直接跑幂等安装器（推送 + 激活 abap/src 下全部 AFF 对象）
node scripts/install.mjs
```

**验证**：

1. `tools/list` 里出现 `stock_check`，且 `inputSchema.properties` 有 `material`/`plant`，`required` 有两者；`description` 取自 DDIC 字段文本。
2. `tools/call` 正常返回 JSON；缺参数返回 `isError:true`。
3. 重连 MCP 客户端（没有 `listChanged` 通知）。

## 6. `raw_args` 模式

当入参是**数组、嵌套对象或需要手写 schema** 时（v1 的 DDIC 模式不支持这些），用 raw 模式：

```abap
  METHOD get_meta.
    rs_meta = VALUE #(
      name       = 'batch_update'
      title      = '批量更新'
      description = '按 JSON 数组批量处理记录（写操作）。'
      raw_args   = abap_true
      raw_schema = '{"type":"object","properties":{"items":{"type":"array","items":'
                && '{"type":"object","properties":{"id":{"type":"string"}}}}},'
                && '"required":["items"],"additionalProperties":false}' ).
  ENDMETHOD.

  METHOD execute.
    " 入参是原始 JSON 文本，自己解析、自己校验
    DATA(lv_args) = iv_args.
    rv_result = zcl_akit_mcp_json=>to_json( ... ).
  ENDMETHOD.
```

- `EXECUTE` 签名改为 `IMPORTING iv_args TYPE string`（框架传原始 `params.arguments` 文本）。
- `args_struct` 留空；`raw_schema` 必须给合法 JSON Schema，否则退化为空 `properties`。
- **内置工具没有任何一个使用 raw 模式**——DDIC 结构已经覆盖它们的入参；只有复杂入参才需要。

## 7. 调试

| 手段 | 用途 |
|---|---|
| `abap run zcl_akit_mcp_setup` | 看注册行校验：`tools` 数量、`invalid[]` 里每个失败原因（类不存在、`GET_META` 签名错、结构不存在） |
| `abap run zcl_akit_mcp_selftest` | 协议层自检（直接调 `ZCL_AKIT_MCP_SERVER`，不经过 ICF）：legacy/modern 方法、错误码、JSON 转义、动态调用 |
| `node scripts/akit-mcp.mjs … tools` / `… call <tool>` | 本地 MCP 客户端：列出 tools、发 `tools/call`、打印原始响应 |
| `tools/list` 看 schema | 直接看模型会看到什么；字段缺描述就补 `@EndUserText.label` |
| `ST22` | 工具内未捕获异常会转成 `isError`，但 dump 仍在 ST22 |
| `SU53` | 权限检查失败时看缺哪个授权对象 |

详细排障见 [troubleshooting.md](troubleshooting.md)。

## 8. 设计建议（给模型看的 API）

tool 的 `description` 与参数 schema 是产品的一部分，写作时按「模型能否选对、能否填对」检验：

- **name**：小写 snake_case 的「名词_动词」或「动词_名词」，与类名后缀对应（`table_read` ↔ `ZCL_AKIT_MCP_TOOL_TABLE_READ`）；不要出现版本号、内部编号、缩写歧义。
- **title**：中文短名；**description**：一两句中文，写清「做什么、只读还是写、有什么限制、什么时候不该用」。不要贴实现细节。
- **参数文本**：DDIC 字段的 `@EndUserText.label` 用中文短语；对可选参数写清默认值语义（例如「0 = 使用服务端配置上限」）。
- **枚举值**：schema 不支持 `enum`，把可选值写进字段文本（如「TABL/VIEW/STRU/DTEL，空 = 自动」）。
- **错误消息**：写成模型能自纠的中文（缺什么参数、值域是什么），不要只抛 `CX_SY_...` 原文。
- **边界**：查询一律有行数上限；写工具必须设 `write = abap_true` 并说明影响；不要在一个 tool 里混合读和写。
- **无副作用**：`GET_META` 纯读取；`EXECUTE` 的副作用要与 `write` 标记一致。

提交前的检查清单：

- [ ] 类名 ≤30 字符、`PUBLIC FINAL CREATE PUBLIC`、`GET_META`/`EXECUTE` 都是 `CLASS-METHODS`
- [ ] DDIC 结构字段名小写、字段文本中文、必填字段写进 `required`
- [ ] `EXECUTE` 有 `AUTHORITY-CHECK`、参数校验、行数上限、`ZCX_AKIT_MCP_TOOL_ERROR`
- [ ] 注册表行 `SERVER` 小写、`TOOL_ENABLED = X`、`TOOL_SORT` 合理
- [ ] 文件小写且符合 AFF 命名；`npm run verify` 通过
- [ ] 真机验证：`tools/list` 的 schema 正确、`tools/call` 成功与失败各一例
