CLASS zcl_akit_mcp_selftest DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

  PRIVATE SECTION.
    TYPES:
      BEGIN OF ty_case,
        name   TYPE string,
        status TYPE i,
        body   TYPE string,
        note   TYPE string,
      END OF ty_case,
      ty_cases TYPE STANDARD TABLE OF ty_case WITH DEFAULT KEY.

    CONSTANTS gc_endpoint TYPE string VALUE 'dev'.

    CLASS-METHODS run_case
      IMPORTING iv_name        TYPE string
                is_request     TYPE zcl_akit_mcp_types=>ty_request
      RETURNING VALUE(rs_case) TYPE ty_case.

    CLASS-METHODS request
      IMPORTING iv_body             TYPE string
                iv_protocol_version TYPE string OPTIONAL
                iv_mcp_method       TYPE string OPTIONAL
                iv_mcp_name         TYPE string OPTIONAL
                iv_endpoint         TYPE string DEFAULT gc_endpoint
      RETURNING VALUE(rs_request)   TYPE zcl_akit_mcp_types=>ty_request.

    CLASS-METHODS modern_meta
      RETURNING VALUE(rv_meta) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_selftest IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.
    DATA lt_cases TYPE ty_cases.
    DATA ls_case  TYPE ty_case.
    DATA lv_meta  TYPE string.

    lv_meta = modern_meta( ).

    APPEND run_case( iv_name    = `legacy_initialize`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":1,"method":"initialize",`
                       && `"params":{"protocolVersion":"2025-11-25","capabilities":{},`
                       && `"clientInfo":{"name":"selftest","version":"1.0"}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `legacy_notification`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","method":"notifications/initialized"}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `legacy_ping`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":"p","method":"ping"}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `legacy_tools_list`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":2,"method":"tools/list"}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `legacy_tools_call_sap_info`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":3,"method":"tools/call",`
                       && `"params":{"name":"sap_info","arguments":{}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `tool_object_search`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":101,"method":"tools/call",`
                       && `"params":{"name":"object_search","arguments":{"pattern":"ZCL_AKIT_MCP_*","objectType":"CLAS"}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `tool_source_read`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":102,"method":"tools/call",`
                       && `"params":{"name":"source_read","arguments":{"objectName":"ZCL_AKIT_MCP_TYPES","maxLines":5}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `tool_syntax_check`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":103,"method":"tools/call",`
                       && `"params":{"name":"syntax_check","arguments":{"source":"REPORT ztest.\nDATA gv TYPE i.\ngv = 1.\nWRITE / gv."}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `tool_ddic_get`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":104,"method":"tools/call",`
                       && `"params":{"name":"ddic_get","arguments":{"objectName":"DD03L"}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `tool_table_read`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":105,"method":"tools/call",`
                       && `"params":{"name":"table_read","arguments":{"tableName":"T000","fields":"MANDT,MTEXT","maxRows":5}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `tool_tcode_info`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":106,"method":"tools/call",`
                       && `"params":{"name":"tcode_info","arguments":{"tcode":"SE38"}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `tool_message_text`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":107,"method":"tools/call",`
                       && `"params":{"name":"message_text","arguments":{"msgClass":"00","msgNo":"001"}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `legacy_unknown_tool`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":4,"method":"tools/call",`
                       && `"params":{"name":"no_such_tool","arguments":{}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `legacy_unknown_method`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":5,"method":"resources/list"}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `invalid_json`
                     is_request = request( iv_body = `{"jsonrpc":` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `null_id`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":null,"method":"ping"}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `unsupported_version`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":6,"method":"tools/list"}`
                                           iv_protocol_version = `2024-01-01` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `initialize_counter_offer`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":7,"method":"initialize",`
                       && `"params":{"protocolVersion":"2026-07-28","capabilities":{}}}` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `modern_discover`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":"d","method":"server/discover",`
                       && `"params":{"_meta":` && lv_meta && `}}`
                                           iv_protocol_version = zcl_akit_mcp_types=>gc_protocol_modern
                                           iv_mcp_method       = `server/discover` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `modern_tools_list`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":"l","method":"tools/list",`
                       && `"params":{"_meta":` && lv_meta && `}}`
                                           iv_protocol_version = zcl_akit_mcp_types=>gc_protocol_modern
                                           iv_mcp_method       = `tools/list` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `modern_initialize_is_404`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":8,"method":"initialize",`
                       && `"params":{"protocolVersion":"2026-07-28","_meta":` && lv_meta && `}}`
                                           iv_protocol_version = zcl_akit_mcp_types=>gc_protocol_modern
                                           iv_mcp_method       = `initialize` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `modern_header_mismatch`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":9,"method":"tools/list",`
                       && `"params":{"_meta":` && lv_meta && `}}`
                                           iv_protocol_version = zcl_akit_mcp_types=>gc_protocol_modern
                                           iv_mcp_method       = `tools/call` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `unknown_endpoint`
                     is_request = request( iv_body = `{"jsonrpc":"2.0","id":10,"method":"ping"}`
                                           iv_endpoint = `nope` ) ) TO lt_cases.

    APPEND run_case( iv_name    = `root_catalogue`
                     is_request = request( iv_body = ``
                                           iv_endpoint = `` ) ) TO lt_cases.

    LOOP AT lt_cases INTO ls_case.
      out->write( zcl_akit_mcp_json=>to_json( ls_case ) ).
    ENDLOOP.
  ENDMETHOD.


  METHOD run_case.
    DATA ls_response TYPE zcl_akit_mcp_types=>ty_response.

    rs_case-name = iv_name.

    TRY.
        ls_response = zcl_akit_mcp_server=>handle( is_request ).
        rs_case-status = ls_response-status.
        rs_case-body   = ls_response-body.
      CATCH cx_root INTO DATA(lx).
        rs_case-status = 500.
        rs_case-note   = lx->get_text( ).
    ENDTRY.
  ENDMETHOD.


  METHOD request.
    IF iv_endpoint IS INITIAL AND iv_body IS NOT INITIAL.
      rs_request-endpoint = gc_endpoint.
    ELSE.
      rs_request-endpoint = iv_endpoint.
    ENDIF.
    rs_request-body             = iv_body.
    rs_request-protocol_version = iv_protocol_version.
    rs_request-mcp_method       = iv_mcp_method.
    rs_request-mcp_name         = iv_mcp_name.
  ENDMETHOD.


  METHOD modern_meta.
    rv_meta = `{"io.modelcontextprotocol/protocolVersion":"2026-07-28",`
           && `"io.modelcontextprotocol/clientCapabilities":{},`
           && `"io.modelcontextprotocol/clientInfo":{"name":"selftest","version":"1.0"}}`.
  ENDMETHOD.

ENDCLASS.
