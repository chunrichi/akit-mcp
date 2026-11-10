CLASS zcl_akit_mcp_tool_ddic_get DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_ddic_get_args
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    " ----- result types (serialized camelCase by ZCL_AKIT_MCP_JSON) -----
    TYPES:
      BEGIN OF ty_field,
        field_name   TYPE string,
        position     TYPE i,
        key_field    TYPE abap_bool,
        data_type    TYPE string,
        length       TYPE i,
        decimals     TYPE i,
        data_element TYPE string,
        domain       TYPE string,
        description  TYPE string,
      END OF ty_field,
      ty_fields TYPE STANDARD TABLE OF ty_field WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_result,
        object_name TYPE string,
        object_type TYPE string,
        description TYPE string,
        data_type   TYPE string,
        length      TYPE i,
        decimals    TYPE i,
        domain      TYPE string,
        fields      TYPE ty_fields,
        truncated   TYPE abap_bool,
      END OF ty_result.

    CLASS-METHODS object_text
      IMPORTING iv_name        TYPE tabname
                iv_object_type TYPE string
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS data_element_text
      IMPORTING iv_rollname    TYPE rollname
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS field_text
      IMPORTING iv_tabname     TYPE tabname
                iv_fieldname   TYPE fieldname
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS max_field_count
      RETURNING VALUE(rv_count) TYPE i.
ENDCLASS.


CLASS zcl_akit_mcp_tool_ddic_get IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'ddic_get'
      title       = 'DDIC 元数据'
      description = '读取表/视图/结构/数据元素的 DDIC 元数据与字段清单（含字段文本）。只读；字段清单最多 500 条。'
      args_struct = 'ZSAKIT_MCP_DDIC_GET_ARGS'
      required    = VALUE #( ( `OBJECT_NAME` ) )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = '' ).
  ENDMETHOD.


  METHOD execute.
    DATA ls_result   TYPE ty_result.
    DATA ls_field    TYPE ty_field.
    DATA ls_dd02l    TYPE dd02l.
    DATA ls_dd04l    TYPE dd04l.
    DATA ls_dd03l    TYPE dd03l.
    DATA lt_dd03l    TYPE STANDARD TABLE OF dd03l.
    DATA lv_name     TYPE tabname.
    DATA lv_type     TYPE string.
    DATA lv_tabclass TYPE tabclass.
    DATA lv_rollname TYPE rollname.
    DATA lv_limit    TYPE i.
    DATA lv_fetch    TYPE i.
    DATA lv_count    TYPE i.
    DATA lv_text     TYPE string.

    " ----- authorization -----
    AUTHORITY-CHECK OBJECT 'S_DEVELOP'
      ID 'ACTVT'    FIELD '03'
      ID 'DEVCLASS' DUMMY
      ID 'OBJTYPE'  DUMMY
      ID 'OBJNAME'  DUMMY
      ID 'P_GROUP'  DUMMY.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少 S_DEVELOP 显示权限（ACTVT=03），无法读取 DDIC 元数据。'.
    ENDIF.

    lv_name = to_upper( condense( is_args-object_name ) ).
    IF lv_name IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '参数 object_name 不能为空。'.
    ENDIF.

    lv_type = to_upper( condense( is_args-object_type ) ).

    " ----- auto-detect: DD02L first (TABL/VIEW/STRU), then DD04L (DTEL) -----
    IF lv_type IS INITIAL.
      SELECT SINGLE tabclass FROM dd02l INTO lv_tabclass
        WHERE tabname = lv_name AND as4local = 'A'.
      IF sy-subrc = 0.
        CASE lv_tabclass.
          WHEN 'VIEW'.
            lv_type = 'VIEW'.
          WHEN 'TRANSP'.
            lv_type = 'TABL'.
          WHEN OTHERS.
            lv_type = 'STRU'.
        ENDCASE.
      ELSE.
        SELECT SINGLE rollname FROM dd04l INTO lv_rollname
          WHERE rollname = lv_name AND as4local = 'A'.
        IF sy-subrc = 0.
          lv_type = 'DTEL'.
        ELSE.
          RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
            EXPORTING iv_details = |DDIC 对象 { lv_name } 不存在（支持 TABL/VIEW/STRU/DTEL）。|.
        ENDIF.
      ENDIF.
    ENDIF.

    CASE lv_type.
      WHEN 'TABL' OR 'VIEW' OR 'STRU'.
        SELECT SINGLE * FROM dd02l INTO ls_dd02l
          WHERE tabname = lv_name AND as4local = 'A'.
        IF sy-subrc <> 0.
          RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
            EXPORTING iv_details = |DDIC 对象 { lv_name } 不存在。|.
        ENDIF.

        ls_result-object_name = lv_name.
        ls_result-object_type = lv_type.
        ls_result-description = object_text( iv_name        = lv_name
                                             iv_object_type = lv_type ).

        lv_limit = max_field_count( ).
        lv_fetch = lv_limit + 1.

        SELECT * FROM dd03l INTO TABLE lt_dd03l
          WHERE tabname = lv_name AND as4local = 'A'
          ORDER BY position.

        DESCRIBE TABLE lt_dd03l LINES lv_count.
        IF lv_count > lv_limit.
          ls_result-truncated = abap_true.
          DELETE lt_dd03l FROM lv_fetch.
        ENDIF.

        LOOP AT lt_dd03l INTO ls_dd03l.
          CLEAR ls_field.
          ls_field-field_name   = ls_dd03l-fieldname.
          ls_field-position     = ls_dd03l-position.
          ls_field-key_field    = boolc( ls_dd03l-keyflag = 'X' ).
          ls_field-data_type    = ls_dd03l-datatype.
          ls_field-length       = ls_dd03l-leng.
          ls_field-decimals     = ls_dd03l-decimals.
          ls_field-data_element = ls_dd03l-rollname.
          ls_field-domain       = ls_dd03l-domname.

          " Description: data element text first, field label second.
          lv_text = data_element_text( ls_dd03l-rollname ).
          IF lv_text IS INITIAL.
            lv_text = field_text( iv_tabname   = lv_name
                                  iv_fieldname = ls_dd03l-fieldname ).
          ENDIF.
          ls_field-description = lv_text.

          APPEND ls_field TO ls_result-fields.
        ENDLOOP.

      WHEN 'DTEL'.
        SELECT SINGLE * FROM dd04l INTO ls_dd04l
          WHERE rollname = lv_name AND as4local = 'A'.
        IF sy-subrc <> 0.
          RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
            EXPORTING iv_details = |数据元素 { lv_name } 不存在。|.
        ENDIF.

        ls_result-object_name = lv_name.
        ls_result-object_type = 'DTEL'.
        ls_result-description = data_element_text( lv_name ).
        ls_result-data_type   = ls_dd04l-datatype.
        ls_result-length      = ls_dd04l-leng.
        ls_result-decimals    = ls_dd04l-decimals.
        ls_result-domain      = ls_dd04l-domname.

      WHEN OTHERS.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |不支持的 DDIC 对象类型 { lv_type }（支持 TABL/VIEW/STRU/DTEL）。|.
    ENDCASE.

    rv_result = zcl_akit_mcp_json=>to_json( ls_result ).
  ENDMETHOD.


  METHOD object_text.
    DATA lv_langu TYPE ddlanguage.

    lv_langu = sy-langu.

    CASE iv_object_type.
      WHEN 'TABL' OR 'VIEW' OR 'STRU'.
        SELECT SINGLE ddtext FROM dd02t INTO rv_text
          WHERE tabname = iv_name AND ddlanguage = lv_langu AND as4local = 'A'.
        IF sy-subrc <> 0.
          SELECT SINGLE ddtext FROM dd02t INTO rv_text
            WHERE tabname = iv_name AND ddlanguage = 'E' AND as4local = 'A'.
        ENDIF.
      WHEN OTHERS.
        CLEAR rv_text.
    ENDCASE.
  ENDMETHOD.


  METHOD data_element_text.
    DATA lv_langu TYPE ddlanguage.

    IF iv_rollname IS INITIAL.
      RETURN.
    ENDIF.

    lv_langu = sy-langu.

    SELECT SINGLE ddtext FROM dd04t INTO rv_text
      WHERE rollname = iv_rollname AND ddlanguage = lv_langu AND as4local = 'A'.
    IF sy-subrc <> 0.
      SELECT SINGLE ddtext FROM dd04t INTO rv_text
        WHERE rollname = iv_rollname AND ddlanguage = 'E' AND as4local = 'A'.
    ENDIF.
  ENDMETHOD.


  METHOD field_text.
    DATA lv_langu TYPE ddlanguage.

    lv_langu = sy-langu.

    SELECT SINGLE ddtext FROM dd03t INTO rv_text
      WHERE tabname = iv_tabname AND fieldname = iv_fieldname
        AND ddlanguage = lv_langu AND as4local = 'A'.
    IF sy-subrc <> 0.
      SELECT SINGLE ddtext FROM dd03t INTO rv_text
        WHERE tabname = iv_tabname AND fieldname = iv_fieldname
          AND ddlanguage = 'E' AND as4local = 'A'.
    ENDIF.
  ENDMETHOD.


  METHOD max_field_count.
    rv_count = zcl_akit_mcp_config=>max_rows_current( ).
    IF rv_count > 500.
      rv_count = 500.
    ENDIF.
    IF rv_count <= 0.
      rv_count = 1.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
