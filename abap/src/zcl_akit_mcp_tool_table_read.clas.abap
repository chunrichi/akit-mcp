CLASS zcl_akit_mcp_tool_table_read DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_table_read_args
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    " ----- JSON filter condition (deserialized with /UI2/CL_JSON) -----
    TYPES:
      BEGIN OF ty_condition,
        field TYPE string,
        op    TYPE string,
        value TYPE string,
      END OF ty_condition,
      ty_conditions TYPE STANDARD TABLE OF ty_condition WITH DEFAULT KEY.

    CLASS-METHODS escape_quotes
      IMPORTING iv_value        TYPE clike
      RETURNING VALUE(rv_value) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_tool_table_read IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'table_read'
      title       = '表数据读取'
      description = '对透明表或视图执行受限只读 SELECT，支持字段投影、JSON 过滤条件、单字段排序与行数上限。只读，不加锁、不写库；默认最多 200 行，硬上限 500。'
      args_struct = 'ZSAKIT_MCP_TABLE_READ_ARGS'
      required    = VALUE #( ( `TABLE_NAME` ) )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = '' ).
  ENDMETHOD.


  METHOD execute.
    DATA lt_conditions  TYPE ty_conditions.
    DATA ls_condition   TYPE ty_condition.
    DATA lt_dd03l       TYPE STANDARD TABLE OF dd03l.
    DATA ls_dd03l       TYPE dd03l.
    DATA lt_field_names TYPE STANDARD TABLE OF fieldname WITH DEFAULT KEY.
    DATA lt_requested   TYPE STANDARD TABLE OF string.
    DATA lr_data        TYPE REF TO data.
    FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.

    DATA lv_table       TYPE tabname.
    DATA lv_tabclass    TYPE tabclass.
    DATA lv_field_name  TYPE fieldname.
    DATA lv_op          TYPE string.
    DATA lv_sql_op      TYPE string.
    DATA lv_value       TYPE string.
    DATA lv_condition   TYPE string.
    DATA lv_where       TYPE string.
    DATA lv_order       TYPE string.
    DATA lv_order_field TYPE fieldname.
    DATA lv_order_dir   TYPE string.
    DATA lv_limit       TYPE i.
    DATA lv_fetch       TYPE i.
    DATA lv_row_count   TYPE i.
    DATA lv_truncated   TYPE abap_bool.
    DATA lv_rows_json   TYPE string.
    DATA lv_table_json  TYPE string.
    DATA lv_trunc_json  TYPE string.
    DATA lv_count_text  TYPE string.
    DATA lx             TYPE REF TO cx_root.

    " ----- validate the table name and its DDIC category -----
    lv_table = to_upper( condense( is_args-table_name ) ).
    IF lv_table IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '参数 table_name 不能为空。'.
    ENDIF.

    SELECT SINGLE tabclass FROM dd02l INTO lv_tabclass
      WHERE tabname = lv_table AND as4local = 'A'.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |表或视图 { lv_table } 不存在。|.
    ENDIF.
    IF lv_tabclass <> 'TRANSP' AND lv_tabclass <> 'VIEW'.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |对象 { lv_table } 的类型为 { lv_tabclass }，仅支持透明表（TRANSP）或视图（VIEW）。|.
    ENDIF.

    " ----- authorization: table display -----
    AUTHORITY-CHECK OBJECT 'S_TABU_NAM'
      ID 'ACTVT' FIELD '03'
      ID 'TABLE' FIELD lv_table.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |缺少表 { lv_table } 的 S_TABU_NAM 显示权限（ACTVT=03）。|.
    ENDIF.

    " ----- resolve the projection (all fields when empty) -----
    SELECT * FROM dd03l INTO TABLE lt_dd03l
      WHERE tabname = lv_table AND as4local = 'A'
      ORDER BY position.
    IF lt_dd03l IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |表 { lv_table } 没有可读取的字段。|.
    ENDIF.

    IF is_args-fields IS NOT INITIAL.
      SPLIT is_args-fields AT ',' INTO TABLE lt_requested.
    ENDIF.

    IF lt_requested IS INITIAL.
      LOOP AT lt_dd03l INTO ls_dd03l.
        APPEND ls_dd03l-fieldname TO lt_field_names.
      ENDLOOP.
    ELSE.
      LOOP AT lt_requested INTO lv_field_name.
        lv_field_name = to_upper( condense( lv_field_name ) ).
        IF lv_field_name IS INITIAL.
          CONTINUE.
        ENDIF.
        READ TABLE lt_dd03l INTO ls_dd03l WITH KEY fieldname = lv_field_name.
        IF sy-subrc <> 0.
          RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
            EXPORTING iv_details = |字段 { lv_field_name } 不属于表 { lv_table }。|.
        ENDIF.
        APPEND lv_field_name TO lt_field_names.
      ENDLOOP.
    ENDIF.
    IF lt_field_names IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '未解析到任何有效返回字段。'.
    ENDIF.

    " ----- parse the JSON filter array -----
    DATA lv_where_json TYPE string.
    lv_where_json = is_args-where_clause.
    IF lv_where_json IS NOT INITIAL.
      TRY.
          /ui2/cl_json=>deserialize(
            EXPORTING json        = lv_where_json
                      pretty_name = /ui2/cl_json=>pretty_mode-camel_case
            CHANGING  data        = lt_conditions ).
        CATCH cx_root INTO lx.
          RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
            EXPORTING iv_details = |参数 where_clause 不是合法的 JSON 数组：{ lx->get_text( ) }|.
      ENDTRY.
      IF lt_conditions IS INITIAL.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = '参数 where_clause 必须是非空的 JSON 数组。'.
      ENDIF.
    ENDIF.

    " ----- build the dynamic WHERE clause: fields are validated first -----
    LOOP AT lt_conditions INTO ls_condition.
      lv_field_name = to_upper( condense( ls_condition-field ) ).
      lv_op         = to_upper( condense( ls_condition-op ) ).
      IF lv_field_name IS INITIAL OR lv_op IS INITIAL.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = 'where_clause 中的每个条件都必须提供 field 与 op。'.
      ENDIF.

      READ TABLE lt_dd03l INTO ls_dd03l WITH KEY fieldname = lv_field_name.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |过滤字段 { lv_field_name } 不属于表 { lv_table }。|.
      ENDIF.

      CASE lv_op.
        WHEN 'EQ'.
          lv_sql_op = '='.
        WHEN 'NE'.
          lv_sql_op = '<>'.
        WHEN 'LT'.
          lv_sql_op = '<'.
        WHEN 'LE'.
          lv_sql_op = '<='.
        WHEN 'GT'.
          lv_sql_op = '>'.
        WHEN 'GE'.
          lv_sql_op = '>='.
        WHEN 'LIKE'.
          lv_sql_op = 'LIKE'.
        WHEN OTHERS.
          RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
            EXPORTING iv_details = |不支持的过滤操作符 { lv_op }（支持 EQ/NE/LT/LE/GT/GE/LIKE）。|.
      ENDCASE.

      IF ls_dd03l-datatype = 'INT1' OR ls_dd03l-datatype = 'INT2'
         OR ls_dd03l-datatype = 'INT4' OR ls_dd03l-datatype = 'INT8'
         OR ls_dd03l-datatype = 'DEC'  OR ls_dd03l-datatype = 'CURR'
         OR ls_dd03l-datatype = 'QUAN' OR ls_dd03l-datatype = 'FLTP'.
        lv_value = condense( ls_condition-value ).
        IF lv_value IS INITIAL.
          RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
            EXPORTING iv_details = |数值字段 { lv_field_name } 的 value 不能为空。|.
        ENDIF.
        lv_condition = lv_field_name && ` ` && lv_sql_op && ` ` && lv_value.
      ELSE.
        lv_value = escape_quotes( ls_condition-value ).
        lv_condition = lv_field_name && ` ` && lv_sql_op && ` '` && lv_value && `'`.
      ENDIF.

      IF lv_where IS NOT INITIAL.
        lv_where = lv_where && ` AND `.
      ENDIF.
      lv_where = lv_where && lv_condition.
    ENDLOOP.

    " ----- optional single-field sort -----
    IF is_args-order_by IS NOT INITIAL.
      lv_order = to_upper( condense( is_args-order_by ) ).
      SPLIT lv_order AT space INTO lv_order_field lv_order_dir.
      IF lv_order_dir IS INITIAL.
        lv_order_dir = 'ASC'.
      ENDIF.
      IF lv_order_dir <> 'ASC' AND lv_order_dir <> 'DESC'.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |排序方向只能是 ASC 或 DESC：{ is_args-order_by }。|.
      ENDIF.
      READ TABLE lt_field_names TRANSPORTING NO FIELDS WITH KEY table_line = lv_order_field.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |排序字段 { lv_order_field } 不在返回字段列表中。|.
      ENDIF.
    ENDIF.

    " ----- row limit: endpoint MAX_ROWS, caller override, hard cap 500 -----
    lv_limit = zcl_akit_mcp_config=>max_rows_current( ).
    IF is_args-max_rows > 0 AND is_args-max_rows < lv_limit.
      lv_limit = is_args-max_rows.
    ENDIF.
    IF lv_limit > 500.
      lv_limit = 500.
    ENDIF.
    IF lv_limit <= 0.
      lv_limit = 1.
    ENDIF.
    lv_fetch = lv_limit + 1.

    " ----- dynamic read: table, projection and WHERE are validated above -----
    CREATE DATA lr_data TYPE STANDARD TABLE OF (lv_table).
    ASSIGN lr_data->* TO <lt_data>.

    TRY.
        IF lv_where IS INITIAL.
          SELECT (lt_field_names) FROM (lv_table) INTO TABLE <lt_data>
            UP TO lv_fetch ROWS.
        ELSE.
          SELECT (lt_field_names) FROM (lv_table) INTO TABLE <lt_data>
            UP TO lv_fetch ROWS
            WHERE (lv_where).
        ENDIF.
      CATCH cx_root INTO lx.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |读取表 { lv_table } 失败：{ lx->get_text( ) }|.
    ENDTRY.

    DESCRIBE TABLE <lt_data> LINES lv_row_count.
    IF lv_row_count > lv_limit.
      lv_truncated = abap_true.
      DELETE <lt_data> FROM lv_fetch.
      lv_row_count = lv_limit.
    ENDIF.

    " Sorting is applied to the returned window only (the SELECT has no
    " dynamic ORDER BY in classic ABAP SQL).
    IF lv_order_field IS NOT INITIAL.
      IF lv_order_dir = 'DESC'.
        SORT <lt_data> BY (lv_order_field) DESCENDING.
      ELSE.
        SORT <lt_data> BY (lv_order_field) ASCENDING.
      ENDIF.
    ENDIF.

    " ----- compose the result envelope (rows are dynamic) -----
    lv_table_json  = zcl_akit_mcp_json=>to_json( lv_table ).
    lv_rows_json   = zcl_akit_mcp_json=>to_json( <lt_data> ).
    lv_trunc_json  = zcl_akit_mcp_json=>to_json( lv_truncated ).
    lv_count_text  = lv_row_count.

    rv_result = `{"tableName":` && lv_table_json
             && `,"rows":` && lv_rows_json
             && `,"rowCount":` && lv_count_text
             && `,"truncated":` && lv_trunc_json
             && `}`.
  ENDMETHOD.


  METHOD escape_quotes.
    DATA lv_quote   TYPE string.
    DATA lv_escaped TYPE string.

    lv_quote   = `'`.
    lv_escaped = lv_quote && lv_quote.
    rv_value   = iv_value.
    REPLACE ALL OCCURRENCES OF lv_quote IN rv_value WITH lv_escaped.
  ENDMETHOD.

ENDCLASS.
