CLASS zcl_akit_mcp_tool_tcode_info DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_tcode_info_args
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    TYPES:
      BEGIN OF ty_result,
        tcode         TYPE string,
        description   TYPE string,
        program       TYPE string,
        dynpro        TYPE string,
        program_title TYPE string,
      END OF ty_result.
ENDCLASS.


CLASS zcl_akit_mcp_tool_tcode_info IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'tcode_info'
      title       = '事务码信息'
      description = '按事务码返回描述、入口程序与屏幕号。只读；登录即可调用。'
      args_struct = 'ZSAKIT_MCP_TCODE_INFO_ARGS'
      required    = VALUE #( ( `TCODE` ) )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = `` ).
  ENDMETHOD.


  METHOD execute.
    DATA ls_result TYPE ty_result.
    DATA lv_tcode  TYPE tstc-tcode.
    DATA lv_langu  TYPE sylangu.

    IF is_args-tcode IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少必填参数 tcode（事务码）'.
    ENDIF.

    lv_tcode = to_upper( is_args-tcode ).

    SELECT SINGLE tcode pgmna dypno FROM tstc INTO (ls_result-tcode, ls_result-program, ls_result-dynpro)
      WHERE tcode = lv_tcode.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |事务码 { lv_tcode } 不存在|.
    ENDIF.

    lv_langu = sy-langu.
    SELECT SINGLE ttext FROM tstct INTO ls_result-description
      WHERE tcode = lv_tcode AND sprsl = lv_langu.
    IF sy-subrc <> 0.
      SELECT SINGLE ttext FROM tstct INTO ls_result-description
        WHERE tcode = lv_tcode AND sprsl = 'E'.
    ENDIF.

    IF ls_result-program IS NOT INITIAL.
      SELECT SINGLE text FROM trdirt INTO ls_result-program_title
        WHERE name = ls_result-program AND sprsl = lv_langu.
      IF sy-subrc <> 0.
        SELECT SINGLE text FROM trdirt INTO ls_result-program_title
          WHERE name = ls_result-program AND sprsl = 'E'.
      ENDIF.
    ENDIF.

    rv_result = zcl_akit_mcp_json=>to_json( ls_result ).
  ENDMETHOD.

ENDCLASS.
