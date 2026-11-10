CLASS zcx_akit_mcp_error DEFINITION
  PUBLIC
  INHERITING FROM cx_static_check
  CREATE PUBLIC.

  PUBLIC SECTION.
    " Stable machine-readable error code (upper snake case).
    DATA code TYPE string READ-ONLY.
    " Human/LLM readable error detail.
    DATA details TYPE string READ-ONLY.

    METHODS constructor
      IMPORTING iv_code    TYPE string
                iv_details TYPE string.

    "! Unified error text (cx_root->get_text is empty for text-less exceptions).
    METHODS get_error_text
      RETURNING VALUE(rv_text) TYPE string.
ENDCLASS.


CLASS zcx_akit_mcp_error IMPLEMENTATION.

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
