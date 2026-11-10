CLASS zcl_akit_mcp_tool_obj_search DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_object_search_args
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    " ----- result types (serialized camelCase by ZCL_AKIT_MCP_JSON) -----
    TYPES:
      BEGIN OF ty_object,
        name        TYPE string,
        object_type TYPE string,
        package     TYPE string,
        author      TYPE string,
        created_on  TYPE string,
        description TYPE string,
      END OF ty_object,
      ty_objects TYPE STANDARD TABLE OF ty_object WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_result,
        objects   TYPE ty_objects,
        count     TYPE i,
        truncated TYPE abap_bool,
      END OF ty_result.

    " ----- TADIR projection -----
    TYPES:
      BEGIN OF ty_tadir_row,
        obj_name   TYPE sobj_name,
        object     TYPE trobjtype,
        devclass   TYPE devclass,
        author     TYPE responsibl,
        created_on TYPE dats,
      END OF ty_tadir_row.

    CLASS-METHODS description_of
      IMPORTING iv_name        TYPE sobj_name
                iv_object_type TYPE trobjtype
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS escape_quotes
      IMPORTING iv_value        TYPE clike
      RETURNING VALUE(rv_value) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_tool_obj_search IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'object_search'
      title       = '对象搜索'
      description = '按名称模式、对象类型和包搜索 TADIR 仓库对象，返回对象名、类型、包、作者、创建日期与描述。只读；最多返回配置上限行数（默认 200，硬上限 500）。'
      args_struct = 'ZSAKIT_MCP_OBJECT_SEARCH_ARGS'
      required    = VALUE #( ( `PATTERN` ) )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = '' ).
  ENDMETHOD.


  METHOD execute.
    DATA lt_rows    TYPE STANDARD TABLE OF ty_tadir_row.
    DATA lt_result  TYPE ty_result.
    DATA ls_row     TYPE ty_tadir_row.
    DATA ls_object  TYPE ty_object.
    DATA lv_pattern TYPE string.
    DATA lv_type    TYPE string.
    DATA lv_package TYPE string.
    DATA lv_where   TYPE string.
    DATA lv_limit   TYPE i.
    DATA lv_fetch   TYPE i.
    DATA lv_count   TYPE i.

    " ----- authorization -----
    AUTHORITY-CHECK OBJECT 'S_DEVELOP'
      ID 'ACTVT'    FIELD '03'
      ID 'DEVCLASS' DUMMY
      ID 'OBJTYPE'  DUMMY
      ID 'OBJNAME'  DUMMY
      ID 'P_GROUP'  DUMMY.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少 S_DEVELOP 显示权限（ACTVT=03），无法搜索仓库对象。'.
    ENDIF.

    " ----- validate the name pattern -----
    lv_pattern = to_upper( condense( is_args-pattern ) ).
    IF lv_pattern IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '参数 pattern 不能为空。'.
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

    " ----- wildcard conversion: * -> %, ? -> _; no wildcard = prefix match -----
    IF lv_pattern CA '*?'.
      REPLACE ALL OCCURRENCES OF '*' IN lv_pattern WITH '%'.
      REPLACE ALL OCCURRENCES OF '?' IN lv_pattern WITH '_'.
    ELSE.
      lv_pattern = lv_pattern && '%'.
    ENDIF.

    " ----- dynamic WHERE over TADIR: repository objects only (PGMID = R3TR) -----
    lv_where = `pgmid = 'R3TR' AND obj_name LIKE '` && escape_quotes( lv_pattern ) && `'`.
    lv_type = to_upper( condense( is_args-object_type ) ).
    IF lv_type IS NOT INITIAL.
      lv_where = lv_where && ` AND object = '` && escape_quotes( lv_type ) && `'`.
    ENDIF.
    lv_package = to_upper( condense( is_args-package_name ) ).
    IF lv_package IS NOT INITIAL.
      lv_where = lv_where && ` AND devclass = '` && escape_quotes( lv_package ) && `'`.
    ENDIF.

    SELECT obj_name, object, devclass, author, created_on
      FROM tadir
      INTO TABLE @lt_rows
      UP TO @lv_fetch ROWS
      WHERE (lv_where).

    " ----- truncate to the effective limit and resolve descriptions -----
    DESCRIBE TABLE lt_rows LINES lv_count.
    IF lv_count > lv_limit.
      lt_result-truncated = abap_true.
      DELETE lt_rows FROM lv_fetch.
    ENDIF.

    LOOP AT lt_rows INTO ls_row.
      CLEAR ls_object.
      ls_object-name        = ls_row-obj_name.
      ls_object-object_type = ls_row-object.
      ls_object-package     = ls_row-devclass.
      ls_object-author      = ls_row-author.
      ls_object-created_on  = ls_row-created_on.
      ls_object-description = description_of( iv_name        = ls_row-obj_name
                                              iv_object_type = ls_row-object ).
      APPEND ls_object TO lt_result-objects.
    ENDLOOP.

    DESCRIBE TABLE lt_result-objects LINES lt_result-count.

    rv_result = zcl_akit_mcp_json=>to_json( lt_result ).
  ENDMETHOD.


  METHOD description_of.
    DATA lv_langu    TYPE ddlanguage.
    DATA lv_clsname  TYPE seoclsname.
    DATA lv_program  TYPE syrepid.
    DATA lv_tabname  TYPE tabname.
    DATA lv_rollname TYPE rollname.
    DATA lv_domname  TYPE domname.
    DATA lv_tcode    TYPE tcode.
    DATA lv_arbgb    TYPE arbgb.

    lv_langu = sy-langu.

    CASE iv_object_type.
      WHEN 'CLAS' OR 'INTF'.
        lv_clsname = iv_name.
        SELECT SINGLE descript FROM seoclasstx INTO rv_text
          WHERE clsname = lv_clsname AND langu = lv_langu.
        IF sy-subrc <> 0.
          SELECT SINGLE descript FROM seoclasstx INTO rv_text
            WHERE clsname = lv_clsname AND langu = 'E'.
        ENDIF.

      WHEN 'PROG'.
        lv_program = iv_name.
        SELECT SINGLE text FROM trdirt INTO rv_text
          WHERE name = lv_program AND sprsl = lv_langu.
        IF sy-subrc <> 0.
          SELECT SINGLE text FROM trdirt INTO rv_text
            WHERE name = lv_program AND sprsl = 'E'.
        ENDIF.

      WHEN 'TABL' OR 'VIEW' OR 'STRU'.
        lv_tabname = iv_name.
        SELECT SINGLE ddtext FROM dd02t INTO rv_text
          WHERE tabname = lv_tabname AND ddlanguage = lv_langu AND as4local = 'A'.
        IF sy-subrc <> 0.
          SELECT SINGLE ddtext FROM dd02t INTO rv_text
            WHERE tabname = lv_tabname AND ddlanguage = 'E' AND as4local = 'A'.
        ENDIF.

      WHEN 'DTEL'.
        lv_rollname = iv_name.
        SELECT SINGLE ddtext FROM dd04t INTO rv_text
          WHERE rollname = lv_rollname AND ddlanguage = lv_langu AND as4local = 'A'.
        IF sy-subrc <> 0.
          SELECT SINGLE ddtext FROM dd04t INTO rv_text
            WHERE rollname = lv_rollname AND ddlanguage = 'E' AND as4local = 'A'.
        ENDIF.

      WHEN 'DOMA'.
        lv_domname = iv_name.
        SELECT SINGLE ddtext FROM dd01t INTO rv_text
          WHERE domname = lv_domname AND ddlanguage = lv_langu AND as4local = 'A'.
        IF sy-subrc <> 0.
          SELECT SINGLE ddtext FROM dd01t INTO rv_text
            WHERE domname = lv_domname AND ddlanguage = 'E' AND as4local = 'A'.
        ENDIF.

      WHEN 'TRAN'.
        lv_tcode = iv_name.
        SELECT SINGLE ttext FROM tstct INTO rv_text
          WHERE tcode = lv_tcode AND sprsl = lv_langu.
        IF sy-subrc <> 0.
          SELECT SINGLE ttext FROM tstct INTO rv_text
            WHERE tcode = lv_tcode AND sprsl = 'E'.
        ENDIF.

      WHEN 'MSAG'.
        lv_arbgb = iv_name.
        SELECT SINGLE stext FROM t100a INTO rv_text
          WHERE arbgb = lv_arbgb.

      WHEN OTHERS.
        CLEAR rv_text.
    ENDCASE.
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
