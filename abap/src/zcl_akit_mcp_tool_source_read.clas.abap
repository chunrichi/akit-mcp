CLASS zcl_akit_mcp_tool_source_read DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_source_read_args
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    CONSTANTS gc_max_lines TYPE i VALUE 5000.

    TYPES:
      BEGIN OF ty_result,
        object_name TYPE string,
        object_type TYPE string,
        line_count  TYPE i,
        truncated   TYPE abap_bool,
        lines       TYPE zcl_akit_mcp_types=>ty_strings,
      END OF ty_result.

    CLASS-METHODS detect_type
      IMPORTING iv_name        TYPE string
      RETURNING VALUE(rv_type) TYPE string.

    CLASS-METHODS read_clif
      IMPORTING iv_name        TYPE string
                iv_max_lines   TYPE i
      RETURNING VALUE(rs_result) TYPE ty_result
      RAISING   zcx_akit_mcp_tool_error.

    CLASS-METHODS read_program
      IMPORTING iv_name        TYPE string
                iv_max_lines   TYPE i
      RETURNING VALUE(rs_result) TYPE ty_result
      RAISING   zcx_akit_mcp_tool_error.
ENDCLASS.


CLASS zcl_akit_mcp_tool_source_read IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'source_read'
      title       = '读取 ABAP 源码'
      description = '读取类/接口/报表程序的 active 版本源码（按行返回），支持行数上限。只读；FUGR 暂不支持。'
      args_struct = 'ZSAKIT_MCP_SOURCE_READ_ARGS'
      required    = VALUE #( ( `OBJECT_NAME` ) )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = `` ).
  ENDMETHOD.


  METHOD execute.
    DATA lv_type   TYPE string.
    DATA lv_name   TYPE string.
    DATA lv_max    TYPE i.
    DATA ls_result TYPE ty_result.

    AUTHORITY-CHECK OBJECT 'S_DEVELOP'
      ID 'ACTVT' FIELD '03'
      ID 'DEVCLASS' DUMMY
      ID 'OBJTYPE' DUMMY
      ID 'OBJNAME' DUMMY
      ID 'P_GROUP' DUMMY.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少 S_DEVELOP（显示）权限，无法读取源码'.
    ENDIF.

    IF is_args-object_name IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少必填参数 object_name（对象名）'.
    ENDIF.

    lv_name = to_upper( condense( is_args-object_name ) ).
    lv_type = to_upper( condense( is_args-object_type ) ).
    IF lv_type IS INITIAL.
      lv_type = detect_type( lv_name ).
    ENDIF.

    lv_max = gc_max_lines.
    IF is_args-max_lines > 0 AND is_args-max_lines < lv_max.
      lv_max = is_args-max_lines.
    ENDIF.

    CASE lv_type.
      WHEN `CLAS` OR `INTF`.
        ls_result = read_clif( iv_name = lv_name iv_max_lines = lv_max ).
      WHEN `PROG`.
        ls_result = read_program( iv_name = lv_name iv_max_lines = lv_max ).
      WHEN OTHERS.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |不支持的对象类型 { lv_type }（v1 支持 CLAS/INTF/PROG）|.
    ENDCASE.

    rv_result = zcl_akit_mcp_json=>to_json( ls_result ).
  ENDMETHOD.


  METHOD detect_type.
    SELECT SINGLE object FROM tadir INTO @DATA(lv_object)
      WHERE pgmid = 'R3TR' AND object = 'CLAS' AND obj_name = @iv_name.
    IF sy-subrc = 0.
      rv_type = `CLAS`.
      RETURN.
    ENDIF.

    SELECT SINGLE object FROM tadir INTO lv_object
      WHERE pgmid = 'R3TR' AND object = 'INTF' AND obj_name = iv_name.
    IF sy-subrc = 0.
      rv_type = `INTF`.
      RETURN.
    ENDIF.

    SELECT SINGLE object FROM tadir INTO lv_object
      WHERE pgmid = 'R3TR' AND object = 'PROG' AND obj_name = iv_name.
    IF sy-subrc = 0.
      rv_type = `PROG`.
    ENDIF.
  ENDMETHOD.


  METHOD read_clif.
    DATA lo_factory TYPE REF TO if_oo_clif_source_factory.
    DATA lo_source  TYPE REF TO if_oo_clif_source.
    DATA lt_source  TYPE rswsourcet.
    DATA ls_line    TYPE rswsources.
    DATA lv_name    TYPE seoclsname.

    rs_result-object_name = iv_name.

    lv_name = iv_name.

    TRY.
        lo_factory = cl_oo_factory=>create_instance( ).
        lo_source  = lo_factory->create_clif_source(
                       clif_name = lv_name
                       version   = if_oo_clif_source=>co_version_active ).
        lo_source->get_source( IMPORTING source = lt_source ).
      CATCH cx_root INTO DATA(lx).
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |读取 { iv_name } 源码失败：{ lx->get_text( ) }|.
    ENDTRY.

    SELECT SINGLE object FROM tadir INTO @DATA(lv_object)
      WHERE pgmid = 'R3TR' AND object IN ( 'CLAS', 'INTF' ) AND obj_name = @iv_name.
    rs_result-object_type = lv_object.

    LOOP AT lt_source INTO ls_line.
      IF lines( rs_result-lines ) >= iv_max_lines.
        rs_result-truncated = abap_true.
        EXIT.
      ENDIF.
      APPEND ls_line-line TO rs_result-lines.
    ENDLOOP.

    rs_result-line_count = lines( rs_result-lines ).
  ENDMETHOD.


  METHOD read_program.
    DATA lt_source TYPE TABLE OF abapsource.
    DATA ls_line   TYPE abapsource.
    DATA lv_prog   TYPE progname.

    rs_result-object_name = iv_name.
    rs_result-object_type = `PROG`.

    lv_prog = iv_name.

    CALL FUNCTION 'RPY_PROGRAM_READ'
      EXPORTING
        program_name = lv_prog
        only_source  = 'X'
      TABLES
        source       = lt_source
      EXCEPTIONS
        cancelled        = 1
        not_found        = 2
        permission_error = 3
        OTHERS           = 4.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |读取程序 { iv_name } 源码失败（sy-subrc={ sy-subrc }）|.
    ENDIF.

    LOOP AT lt_source INTO ls_line.
      IF lines( rs_result-lines ) >= iv_max_lines.
        rs_result-truncated = abap_true.
        EXIT.
      ENDIF.
      APPEND ls_line-line TO rs_result-lines.
    ENDLOOP.

    rs_result-line_count = lines( rs_result-lines ).
  ENDMETHOD.

ENDCLASS.
