CLASS zcl_akit_mcp_tool_message_text DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      IMPORTING is_args         TYPE zsakit_mcp_message_text_args
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    TYPES:
      BEGIN OF ty_result,
        message_class   TYPE string,
        description     TYPE string,
        message_number  TYPE string,
        text            TYPE string,
      END OF ty_result.

    CLASS-METHODS replace_variables
      IMPORTING iv_text      TYPE string
                iv_variables TYPE string
      RETURNING VALUE(rv_text) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_tool_message_text IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'message_text'
      title       = 'T100 消息文本'
      description = '按消息类与消息编号返回 T100 文本；variables 用 | 分隔，依次替换文本中的 & 占位符。只读；登录即可调用。'
      args_struct = 'ZSAKIT_MCP_MESSAGE_TEXT_ARGS'
      required    = VALUE #( ( `MSG_CLASS` ) ( `MSG_NO` ) )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = `` ).
  ENDMETHOD.


  METHOD execute.
    DATA ls_result  TYPE ty_result.
    DATA lv_class     TYPE t100a-arbgb.
    DATA lv_number    TYPE t100-msgnr.
    DATA lv_langu     TYPE sylangu.
    DATA lv_variables TYPE string.

    IF is_args-msg_class IS INITIAL OR is_args-msg_no IS INITIAL.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = '缺少必填参数 msg_class / msg_no（消息类与消息编号）'.
    ENDIF.

    lv_class  = to_upper( is_args-msg_class ).
    lv_number = is_args-msg_no.
    lv_langu  = sy-langu.

    SELECT SINGLE arbgb stext FROM t100a INTO (ls_result-message_class, ls_result-description)
      WHERE arbgb = lv_class.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |消息类 { lv_class } 不存在|.
    ENDIF.

    ls_result-message_number = lv_number.

    SELECT SINGLE text FROM t100 INTO ls_result-text
      WHERE sprsl = lv_langu AND arbgb = lv_class AND msgnr = lv_number.
    IF sy-subrc <> 0.
      SELECT SINGLE text FROM t100 INTO ls_result-text
        WHERE sprsl = 'E' AND arbgb = lv_class AND msgnr = lv_number.
    ENDIF.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_akit_mcp_tool_error
        EXPORTING iv_details = |消息 { lv_class }/{ lv_number } 不存在|.
    ENDIF.

    lv_variables   = is_args-variables.
    ls_result-text = replace_variables( iv_text = ls_result-text iv_variables = lv_variables ).

    rv_result = zcl_akit_mcp_json=>to_json( ls_result ).
  ENDMETHOD.


  METHOD replace_variables.
    DATA lt_variables TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
    DATA lv_value     TYPE string.

    rv_text = iv_text.

    IF iv_variables IS INITIAL.
      RETURN.
    ENDIF.

    SPLIT iv_variables AT `|` INTO TABLE lt_variables.

    LOOP AT lt_variables INTO lv_value.
      lv_value = condense( lv_value ).
      IF lv_value IS INITIAL.
        CONTINUE.
      ENDIF.
      REPLACE FIRST OCCURRENCE OF `&` IN rv_text WITH lv_value.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.
