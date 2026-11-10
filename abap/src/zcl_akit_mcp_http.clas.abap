CLASS zcl_akit_mcp_http DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_http_extension.

  PRIVATE SECTION.
    CLASS-METHODS handle
      IMPORTING io_server TYPE REF TO if_http_server.

    "! Map the ICF sub-path to an MCP endpoint name:
    "!   /dev        -> dev
    "!   /dev/       -> dev
    "!   '' or /     -> '' (endpoint catalogue)
    "!   /a/b        -> invalid
    CLASS-METHODS parse_endpoint
      IMPORTING iv_path         TYPE string
      EXPORTING ev_endpoint     TYPE string
                ev_valid        TYPE abap_bool.

    CLASS-METHODS respond
      IMPORTING io_response  TYPE REF TO if_http_response
                iv_status    TYPE i
                iv_body      TYPE string
                iv_origin    TYPE string
                iv_server    TYPE string
                iv_allow     TYPE string OPTIONAL.

    CLASS-METHODS respond_transport_error
      IMPORTING io_response TYPE REF TO if_http_response
                iv_status   TYPE i
                iv_code     TYPE i
                iv_message  TYPE string
                iv_origin   TYPE string
                iv_server   TYPE string
                iv_allow    TYPE string OPTIONAL.

    CLASS-METHODS set_cors
      IMPORTING io_response TYPE REF TO if_http_response
                iv_origin   TYPE string
                iv_server   TYPE string.

    CLASS-METHODS origin_allowed
      IMPORTING iv_origin        TYPE string
                iv_server        TYPE string
      RETURNING VALUE(rv_allowed) TYPE abap_bool.

    CLASS-METHODS reason
      IMPORTING iv_status        TYPE i
      RETURNING VALUE(rv_reason) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_http IMPLEMENTATION.

  METHOD if_http_extension~handle_request.
    DATA lo_server TYPE REF TO if_http_server.

    lo_server = server.
    " MCP Streamable HTTP is stateless here: never keep an ICF session alive.
    lo_server->set_session_stateful( stateful = if_http_server=>co_disabled ).

    TRY.
        handle( lo_server ).
      CATCH cx_root INTO DATA(lx).
        respond_transport_error( io_response = lo_server->response
                                 iv_status   = 500
                                 iv_code     = zcl_akit_mcp_types=>c_error-internal_error
                                 iv_message  = |AKIT MCP internal error: { lx->get_text( ) }|
                                 iv_origin   = lo_server->request->get_header_field( `origin` )
                                 iv_server   = `` ).
    ENDTRY.
  ENDMETHOD.


  METHOD handle.
    DATA lo_request      TYPE REF TO if_http_request.
    DATA lo_response     TYPE REF TO if_http_response.
    DATA lv_method       TYPE string.
    DATA lv_origin       TYPE string.
    DATA lv_accept       TYPE string.
    DATA lv_content_type TYPE string.
    DATA lv_endpoint     TYPE string.
    DATA lv_valid        TYPE abap_bool.

    lo_request  = io_server->request.
    lo_response = io_server->response.

    lv_method = to_upper( lo_request->get_method( ) ).
    lv_origin = lo_request->get_header_field( `origin` ).

    parse_endpoint( EXPORTING iv_path     = lo_request->get_header_field( `~path_info` )
                    IMPORTING ev_endpoint = lv_endpoint
                              ev_valid    = lv_valid ).
    IF lv_valid = abap_false.
      respond_transport_error( io_response = lo_response
                               iv_status   = 404
                               iv_code     = zcl_akit_mcp_types=>c_error-invalid_request
                               iv_message  = `unknown MCP endpoint path; expected /sap/bc/mcp/<endpoint>`
                               iv_origin   = lv_origin
                               iv_server   = lv_endpoint ).
      RETURN.
    ENDIF.

    " Browser CORS preflight comes before any origin gate.
    IF lv_method = `OPTIONS`.
      respond( io_response = lo_response
               iv_status   = 204
               iv_body     = ``
               iv_origin   = lv_origin
               iv_server   = lv_endpoint
               iv_allow    = `POST, OPTIONS` ).
      RETURN.
    ENDIF.

    IF lv_origin IS NOT INITIAL AND origin_allowed( iv_origin = lv_origin
                                                    iv_server = lv_endpoint ) = abap_false.
      respond_transport_error( io_response = lo_response
                               iv_status   = 403
                               iv_code     = zcl_akit_mcp_types=>c_error-invalid_request
                               iv_message  = 'origin not allowed: configure ORIGINS to accept browser clients'
                               iv_origin   = lv_origin
                               iv_server   = lv_endpoint ).
      RETURN.
    ENDIF.

    CASE lv_method.
      WHEN `POST`.
        lv_accept = to_lower( lo_request->get_header_field( `accept` ) ).
        IF lv_accept IS NOT INITIAL
           AND lv_accept NS `application/json`
           AND lv_accept NS `text/event-stream`
           AND lv_accept NS `*/*`.
          respond_transport_error( io_response = lo_response
                                   iv_status   = 406
                                   iv_code     = zcl_akit_mcp_types=>c_error-invalid_request
                                   iv_message  = 'Accept header must allow application/json'
                                   iv_origin   = lv_origin
                                   iv_server   = lv_endpoint ).
          RETURN.
        ENDIF.

        lv_content_type = to_lower( lo_request->get_header_field( `content-type` ) ).
        IF lv_content_type IS NOT INITIAL AND lv_content_type NS `application/json`.
          respond_transport_error( io_response = lo_response
                                   iv_status   = 415
                                   iv_code     = zcl_akit_mcp_types=>c_error-invalid_request
                                   iv_message  = 'Content-Type must be application/json'
                                   iv_origin   = lv_origin
                                   iv_server   = lv_endpoint ).
          RETURN.
        ENDIF.

        DATA(ls_request) = VALUE zcl_akit_mcp_types=>ty_request(
          endpoint         = lv_endpoint
          body             = lo_request->get_cdata( )
          protocol_version = lo_request->get_header_field( `mcp-protocol-version` )
          mcp_method       = lo_request->get_header_field( `mcp-method` )
          mcp_name         = lo_request->get_header_field( `mcp-name` )
          origin           = lv_origin ).

        DATA(ls_result) = zcl_akit_mcp_server=>handle( ls_request ).

        respond( io_response = lo_response
                 iv_status   = ls_result-status
                 iv_body     = ls_result-body
                 iv_origin   = lv_origin
                 iv_server   = lv_endpoint ).

      WHEN `GET` OR `HEAD`.
        " The bare node publishes the endpoint catalogue; an endpoint itself is
        " POST-only (this server never exposes an SSE GET stream).
        IF lv_endpoint IS INITIAL.
          DATA(ls_result_get) = zcl_akit_mcp_server=>handle(
            VALUE zcl_akit_mcp_types=>ty_request( endpoint = `` ) ).
          respond( io_response = lo_response
                   iv_status   = ls_result_get-status
                   iv_body     = ls_result_get-body
                   iv_origin   = lv_origin
                   iv_server   = lv_endpoint ).
        ELSE.
          respond_transport_error( io_response = lo_response
                                   iv_status   = 405
                                   iv_code     = zcl_akit_mcp_types=>c_error-invalid_request
                                   iv_message  = 'only POST is supported by this stateless MCP endpoint'
                                   iv_origin   = lv_origin
                                   iv_server   = lv_endpoint
                                   iv_allow    = `POST, OPTIONS` ).
        ENDIF.

      WHEN OTHERS.
        respond_transport_error( io_response = lo_response
                                 iv_status   = 405
                                 iv_code     = zcl_akit_mcp_types=>c_error-invalid_request
                                 iv_message  = |HTTP method { lv_method } is not supported|
                                 iv_origin   = lv_origin
                                 iv_server   = lv_endpoint
                                 iv_allow    = `POST, OPTIONS` ).
    ENDCASE.
  ENDMETHOD.


  METHOD parse_endpoint.
    DATA lt_parts TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
    DATA lv_part  TYPE string.

    ev_endpoint = ``.
    ev_valid    = abap_true.

    SPLIT iv_path AT `/` INTO TABLE lt_parts.
    DELETE lt_parts WHERE table_line IS INITIAL.

    IF lines( lt_parts ) = 0.
      RETURN.
    ENDIF.

    IF lines( lt_parts ) > 1.
      ev_valid = abap_false.
      RETURN.
    ENDIF.

    lv_part = to_lower( lt_parts[ 1 ] ).
    IF strlen( lv_part ) > 30
       OR NOT lv_part CO `abcdefghijklmnopqrstuvwxyz0123456789-_`.
      ev_valid = abap_false.
      RETURN.
    ENDIF.

    ev_endpoint = lv_part.
  ENDMETHOD.


  METHOD respond.
    io_response->set_status( code = iv_status reason = reason( iv_status ) ).
    io_response->set_header_field( name = `cache-control` value = `no-store` ).
    io_response->set_header_field( name = `x-akit-mcp-version` value = zcl_akit_mcp_types=>gc_version ).
    IF iv_allow IS NOT INITIAL.
      io_response->set_header_field( name = `allow` value = iv_allow ).
    ENDIF.

    IF iv_body IS NOT INITIAL.
      io_response->set_content_type( zcl_akit_mcp_types=>gc_content_type ).
      io_response->set_cdata( iv_body ).
    ENDIF.

    set_cors( io_response = io_response iv_origin = iv_origin iv_server = iv_server ).
  ENDMETHOD.


  METHOD respond_transport_error.
    DATA lv_body TYPE string.

    lv_body = zcl_akit_mcp_json=>rpc_error( iv_id_raw  = 'null'
                                            iv_code    = iv_code
                                            iv_message = iv_message ).

    respond( io_response = io_response
             iv_status   = iv_status
             iv_body     = lv_body
             iv_origin   = iv_origin
             iv_server   = iv_server
             iv_allow    = iv_allow ).
  ENDMETHOD.


  METHOD set_cors.
    IF iv_origin IS INITIAL OR origin_allowed( iv_origin = iv_origin
                                               iv_server = iv_server ) = abap_false.
      RETURN.
    ENDIF.

    io_response->set_header_field( name = `access-control-allow-origin` value = iv_origin ).
    io_response->set_header_field( name = `vary` value = `Origin` ).
    io_response->set_header_field( name = `access-control-allow-methods` value = `POST, OPTIONS` ).
    io_response->set_header_field( name = `access-control-allow-headers`
      value = `content-type, accept, authorization, mcp-protocol-version, mcp-method, mcp-name, mcp-session-id` ).
    io_response->set_header_field( name = `access-control-max-age` value = `3600` ).
  ENDMETHOD.


  METHOD origin_allowed.
    DATA lt_origins TYPE zcl_akit_mcp_types=>ty_strings.

    lt_origins = zcl_akit_mcp_config=>origins( iv_server ).
    IF lt_origins IS INITIAL.
      RETURN.
    ENDIF.

    rv_allowed = boolc( line_exists( lt_origins[ table_line = to_upper( iv_origin ) ] ) ).
  ENDMETHOD.


  METHOD reason.
    CASE iv_status.
      WHEN 200. rv_reason = `OK`.
      WHEN 202. rv_reason = `Accepted`.
      WHEN 204. rv_reason = `No Content`.
      WHEN 400. rv_reason = `Bad Request`.
      WHEN 403. rv_reason = `Forbidden`.
      WHEN 404. rv_reason = `Not Found`.
      WHEN 405. rv_reason = `Method Not Allowed`.
      WHEN 406. rv_reason = `Not Acceptable`.
      WHEN 415. rv_reason = `Unsupported Media Type`.
      WHEN 503. rv_reason = `Service Unavailable`.
      WHEN OTHERS. rv_reason = `Internal Server Error`.
    ENDCASE.
  ENDMETHOD.

ENDCLASS.
