CLASS zcx_akit_mcp_tool_error DEFINITION
  PUBLIC
  INHERITING FROM cx_static_check
  CREATE PUBLIC.

  PUBLIC SECTION.
    DATA code TYPE string READ-ONLY.
    DATA details TYPE string READ-ONLY.

    METHODS constructor
      IMPORTING iv_details TYPE string
                iv_code    TYPE string DEFAULT 'TOOL_ERROR'.

    METHODS get_error_text
      RETURNING VALUE(rv_text) TYPE string.
ENDCLASS.


CLASS zcx_akit_mcp_tool_error IMPLEMENTATION.

  METHOD constructor.
    super->constructor( ).
    code    = iv_code.
    details = iv_details.
  ENDMETHOD.

  METHOD get_error_text.
    rv_text = details.
    IF rv_text IS INITIAL.
      rv_text = code.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
