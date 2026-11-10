CLASS zcl_akit_mcp_config DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    "! Raw configuration value for one MCP endpoint. Falls back to the global
    "! row (SERVER = '*') and returns '' when nothing is maintained.
    CLASS-METHODS get
      IMPORTING iv_server      TYPE string
                iv_name        TYPE string
      RETURNING VALUE(rv_value) TYPE string.

    CLASS-METHODS get_bool
      IMPORTING iv_server       TYPE string
                iv_name         TYPE string
                iv_default      TYPE abap_bool
      RETURNING VALUE(rv_value) TYPE abap_bool.

    CLASS-METHODS get_int
      IMPORTING iv_server       TYPE string
                iv_name         TYPE string
                iv_default      TYPE i
      RETURNING VALUE(rv_value) TYPE i.

    "! Per-endpoint kill switch, default on.
    CLASS-METHODS enabled
      IMPORTING iv_server        TYPE string
      RETURNING VALUE(rv_enabled) TYPE abap_bool.

    "! Read-only endpoint: write tools are hidden and rejected. Default on.
    CLASS-METHODS read_only
      IMPORTING iv_server          TYPE string
      RETURNING VALUE(rv_read_only) TYPE abap_bool.

    "! Row limit for query-like tools (default 200, hard cap 5000).
    CLASS-METHODS max_rows
      IMPORTING iv_server      TYPE string
      RETURNING VALUE(rv_rows) TYPE i.

    "! serverInfo title shown to clients.
    CLASS-METHODS title
      IMPORTING iv_server       TYPE string
      RETURNING VALUE(rv_title) TYPE string.

    "! Allowed CORS origins (empty = browser clients are rejected).
    CLASS-METHODS origins
      IMPORTING iv_server        TYPE string
      RETURNING VALUE(rt_origins) TYPE zcl_akit_mcp_types=>ty_strings.

    "! True when the endpoint has any tool or configuration row.
    CLASS-METHODS endpoint_exists
      IMPORTING iv_server         TYPE string
      RETURNING VALUE(rv_exists)  TYPE abap_bool.

    "! The endpoint of the request currently being served. Tool implementations
    "! read their row limit through MAX_ROWS_CURRENT, because the tool call
    "! contract intentionally carries no endpoint parameter.
    CLASS-METHODS set_endpoint
      IMPORTING iv_server TYPE string.

    "! MAX_ROWS of the endpoint currently being served.
    CLASS-METHODS max_rows_current
      RETURNING VALUE(rv_rows) TYPE i.

  PRIVATE SECTION.
    CLASS-DATA gv_endpoint TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_config IMPLEMENTATION.

  METHOD set_endpoint.
    gv_endpoint = to_lower( iv_server ).
  ENDMETHOD.


  METHOD max_rows_current.
    rv_rows = max_rows( gv_endpoint ).
  ENDMETHOD.

  METHOD get.
    DATA lv_server TYPE string.
    DATA lv_value  TYPE string.

    lv_server = to_lower( iv_server ).

    SELECT SINGLE conf_value FROM ztakit_mcp_conf INTO lv_value
      WHERE server = lv_server AND conf_name = iv_name.
    IF sy-subrc <> 0 AND lv_server IS NOT INITIAL.
      SELECT SINGLE conf_value FROM ztakit_mcp_conf INTO lv_value
        WHERE server = zcl_akit_mcp_types=>gc_server_global AND conf_name = iv_name.
    ENDIF.

    rv_value = lv_value.
  ENDMETHOD.


  METHOD get_bool.
    DATA lv_value TYPE string.

    lv_value = to_upper( get( iv_server = iv_server iv_name = iv_name ) ).
    IF lv_value IS INITIAL.
      rv_value = iv_default.
    ELSE.
      rv_value = boolc( lv_value = `X` OR lv_value = `TRUE` OR lv_value = `1` ).
    ENDIF.
  ENDMETHOD.


  METHOD get_int.
    DATA lv_value TYPE string.

    lv_value = get( iv_server = iv_server iv_name = iv_name ).
    IF lv_value IS INITIAL.
      rv_value = iv_default.
      RETURN.
    ENDIF.

    TRY.
        rv_value = lv_value.
      CATCH cx_sy_conversion_no_number.
        rv_value = iv_default.
    ENDTRY.
  ENDMETHOD.


  METHOD enabled.
    rv_enabled = get_bool( iv_server  = iv_server
                           iv_name    = zcl_akit_mcp_types=>gc_conf_enabled
                           iv_default = abap_true ).
  ENDMETHOD.


  METHOD read_only.
    rv_read_only = get_bool( iv_server  = iv_server
                             iv_name    = zcl_akit_mcp_types=>gc_conf_read_only
                             iv_default = abap_true ).
  ENDMETHOD.


  METHOD max_rows.
    rv_rows = get_int( iv_server  = iv_server
                       iv_name    = zcl_akit_mcp_types=>gc_conf_max_rows
                       iv_default = 200 ).
    IF rv_rows <= 0.
      rv_rows = 200.
    ENDIF.
    IF rv_rows > zcl_akit_mcp_types=>gc_max_rows_hard.
      rv_rows = zcl_akit_mcp_types=>gc_max_rows_hard.
    ENDIF.
  ENDMETHOD.


  METHOD title.
    rv_title = get( iv_server = iv_server
                    iv_name   = zcl_akit_mcp_types=>gc_conf_title ).
    IF rv_title IS INITIAL.
      rv_title = |{ zcl_akit_mcp_types=>gc_server_title } - { to_lower( iv_server ) }|.
    ENDIF.
  ENDMETHOD.


  METHOD origins.
    DATA lv_value TYPE string.

    lv_value = get( iv_server = iv_server
                    iv_name   = zcl_akit_mcp_types=>gc_conf_origins ).
    IF lv_value IS INITIAL.
      RETURN.
    ENDIF.

    SPLIT lv_value AT ',' INTO TABLE rt_origins.

    DATA lt_result TYPE zcl_akit_mcp_types=>ty_strings.
    LOOP AT rt_origins INTO DATA(lv_origin).
      lv_origin = to_upper( condense( lv_origin ) ).
      IF lv_origin IS NOT INITIAL.
        APPEND lv_origin TO lt_result.
      ENDIF.
    ENDLOOP.
    rt_origins = lt_result.
  ENDMETHOD.


  METHOD endpoint_exists.
    DATA lv_server TYPE string.
    DATA lv_dummy  TYPE string.

    lv_server = to_lower( iv_server ).

    SELECT SINGLE tool_class FROM ztakit_mcp_tool INTO lv_dummy
      WHERE server = lv_server.
    IF sy-subrc = 0.
      rv_exists = abap_true.
      RETURN.
    ENDIF.

    SELECT SINGLE conf_value FROM ztakit_mcp_conf INTO lv_dummy
      WHERE server = lv_server.
    IF sy-subrc = 0.
      rv_exists = abap_true.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
