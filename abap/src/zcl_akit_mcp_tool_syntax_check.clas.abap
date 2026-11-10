CLASS zcl_akit_mcp_tool_syntax_check DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_syntax_check_args
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    CONSTANTS gc_context_program TYPE progname VALUE 'ZAKIT_MCP_SYNTAX_CONTEXT'.
    CONSTANTS gc_max_lines       TYPE i VALUE 5000.

    TYPES:
      BEGIN OF ty_result,
        valid       TYPE abap_bool,
        return_code TYPE i,
        line        TYPE i,
        word        TYPE string,
        message     TYPE string,
        line_count  TYPE i,
        program     TYPE string,
      END OF ty_result.
ENDCLASS.


CLASS zcl_akit_mcp_tool_syntax_check IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'syntax_check'
      title       = 'ABAP 语法检查'
      description = '对一段完整编译单元的 ABAP 源码做语法检查（不保存、不激活），返回是否通过、错误行号/单词/消息。上下文默认使用内置报表 ZAKIT_MCP_SYNTAX_CONTEXT。只读。'
      args_struct = 'ZSAKIT_MCP_SYNTAX_CHECK_ARGS'
      required    = VALUE #( ( `SOURCE` ) )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = `` ).
  ENDMETHOD.


  METHOD execute.
    DATA ls_result  TYPE ty_result.
    DATA lt_lines   TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
    DATA lv_source  TYPE string.
    DATA lv_crlf    TYPE string.
    DATA lv_lf      TYPE string.
    DATA lv_program TYPE progname.
    DATA lv_message TYPE string.
    DATA lv_line    TYPE i.
    DATA lv_word    TYPE string.

    AUTHORITY-CHECK OBJECT 'S_DEVELOP'
      ID 'ACTVT' FIELD '03'
      ID 'DEVCLASS' DUMMY
      ID 'OBJTYPE' DUMMY
      ID 'OBJNAME' DUMMY
      ID 'P_GROUP' DUMMY.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少 S_DEVELOP（显示）权限，无法做语法检查'.
    ENDIF.

    IF is_args-source IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少必填参数 source（待检查的 ABAP 源码）'.
    ENDIF.

    " Normalize CRLF -> LF and split into source lines.
    lv_crlf = cl_abap_char_utilities=>cr_lf.
    lv_lf   = lv_crlf+1(1).
    lv_source = is_args-source.
    REPLACE ALL OCCURRENCES OF lv_crlf IN lv_source WITH lv_lf.
    SPLIT lv_source AT lv_lf INTO TABLE lt_lines.

    IF lines( lt_lines ) > gc_max_lines.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |源码超过 { gc_max_lines } 行，请拆分后检查|.
    ENDIF.

    " A report program is required as SYNTAX-CHECK context; a class pool is
    " rejected with "Statement is not accessible".
    IF is_args-program_name IS NOT INITIAL.
      lv_program = to_upper( condense( is_args-program_name ) ).
      SELECT SINGLE object FROM tadir INTO @DATA(lv_object)
        WHERE pgmid = 'R3TR' AND object = 'PROG' AND obj_name = @lv_program.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
          EXPORTING iv_details = |上下文程序 { lv_program } 不存在|.
      ENDIF.
    ELSE.
      lv_program = gc_context_program.
    ENDIF.

    SYNTAX-CHECK FOR lt_lines
      MESSAGE lv_message
      LINE    lv_line
      WORD    lv_word
      PROGRAM lv_program.

    ls_result-valid       = boolc( sy-subrc = 0 ).
    ls_result-return_code = sy-subrc.
    ls_result-line        = lv_line.
    ls_result-word        = lv_word.
    ls_result-message     = lv_message.
    ls_result-line_count  = lines( lt_lines ).
    ls_result-program     = lv_program.

    rv_result = zcl_akit_mcp_json=>to_json_full( ls_result ).
  ENDMETHOD.

ENDCLASS.
