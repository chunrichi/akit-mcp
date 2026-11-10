CLASS zcl_akit_mcp_server DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    "! Single stateless entry point: one JSON-RPC request in, one HTTP response
    "! description out. No ICF object is touched below this layer.
    "!
    "! is_request-endpoint selects the MCP endpoint (the path segment after the
    "! ICF node, e.g. `dev` for /sap/bc/mcp/dev). An empty endpoint returns the
    "! endpoint catalogue instead of an MCP response.
    CLASS-METHODS handle
      IMPORTING is_request         TYPE zcl_akit_mcp_types=>ty_request
      RETURNING VALUE(rs_response) TYPE zcl_akit_mcp_types=>ty_response.

  PRIVATE SECTION.
    " ----- versions / era -----
    CLASS-METHODS is_legacy_version
      IMPORTING iv_version       TYPE string
      RETURNING VALUE(rv_legacy) TYPE abap_bool.

    CLASS-METHODS is_modern_version
      IMPORTING iv_version       TYPE string
      RETURNING VALUE(rv_modern) TYPE abap_bool.

    CLASS-METHODS is_supported_version
      IMPORTING iv_version          TYPE string
      RETURNING VALUE(rv_supported) TYPE abap_bool.

    " ----- payload builders -----
    CLASS-METHODS build_root
      RETURNING VALUE(rv_body) TYPE string.

    CLASS-METHODS server_info
      IMPORTING iv_endpoint    TYPE string
      RETURNING VALUE(rs_info) TYPE zcl_akit_mcp_types=>ty_server_info.

    CLASS-METHODS instructions_text
      IMPORTING iv_endpoint    TYPE string
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS build_initialize
      IMPORTING iv_endpoint         TYPE string
                iv_protocol_version TYPE string
      RETURNING VALUE(rv_payload)   TYPE string.

    CLASS-METHODS build_tools_list
      IMPORTING iv_endpoint    TYPE string
      RETURNING VALUE(rv_payload) TYPE string.

    CLASS-METHODS build_tools_call
      IMPORTING iv_endpoint     TYPE string
                iv_params       TYPE zcl_akit_mcp_types=>ty_params
      EXPORTING ev_payload      TYPE string
                ev_error_code   TYPE i
                ev_error_text   TYPE string.

    CLASS-METHODS build_discover
      IMPORTING iv_endpoint    TYPE string
      RETURNING VALUE(rv_payload) TYPE string.

    " ----- envelopes -----
    CLASS-METHODS result_response
      IMPORTING iv_endpoint       TYPE string
                iv_payload        TYPE string
                iv_id_raw         TYPE string
                iv_modern         TYPE abap_bool
                iv_cacheable      TYPE abap_bool DEFAULT abap_false
      RETURNING VALUE(rs_response) TYPE zcl_akit_mcp_types=>ty_response.

    CLASS-METHODS error_response
      IMPORTING iv_status      TYPE i
                iv_code        TYPE i
                iv_message     TYPE string
                iv_id_raw      TYPE string
                iv_data_json   TYPE string OPTIONAL
      RETURNING VALUE(rs_response) TYPE zcl_akit_mcp_types=>ty_response.

    CLASS-METHODS modern_extras
      IMPORTING iv_endpoint    TYPE string
                iv_cacheable   TYPE abap_bool
      RETURNING VALUE(rv_extra) TYPE string.

    CLASS-METHODS supported_versions
      RETURNING VALUE(rt_versions) TYPE zcl_akit_mcp_types=>ty_strings.

    CLASS-METHODS version_error_data
      IMPORTING iv_version    TYPE string
      RETURNING VALUE(rv_json) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_server IMPLEMENTATION.

  METHOD handle.
    DATA lv_header_ver TYPE string.
    DATA lv_meta_ver   TYPE string.
    DATA lv_modern     TYPE abap_bool.
    DATA lv_endpoint   TYPE string.
    DATA lv_payload    TYPE string.
    DATA lv_error_code TYPE i.
    DATA lv_error_text TYPE string.

    rs_response-content_type = zcl_akit_mcp_types=>gc_content_type.
    lv_endpoint = to_lower( is_request-endpoint ).

    " Tool implementations read their row limit through the config class; the
    " endpoint of the current request is the only ambient context needed.
    zcl_akit_mcp_config=>set_endpoint( lv_endpoint ).

    " Bare ICF node: publish the endpoint catalogue (human/agent discovery).
    IF lv_endpoint IS INITIAL.
      rs_response-status       = 200.
      rs_response-content_type = zcl_akit_mcp_types=>gc_content_type.
      rs_response-body         = build_root( ).
      RETURN.
    ENDIF.

    IF zcl_akit_mcp_config=>endpoint_exists( lv_endpoint ) = abap_false.
      rs_response = error_response( iv_status  = 404
                                    iv_code    = zcl_akit_mcp_types=>c_error-invalid_request
                                    iv_message = |unknown MCP endpoint: { lv_endpoint }|
                                    iv_id_raw  = 'null' ).
      RETURN.
    ENDIF.

    IF zcl_akit_mcp_config=>enabled( lv_endpoint ) = abap_false.
      rs_response = error_response( iv_status  = 503
                                    iv_code    = zcl_akit_mcp_types=>c_error-internal_error
                                    iv_message = |MCP endpoint { lv_endpoint } is disabled by configuration|
                                    iv_id_raw  = 'null' ).
      RETURN.
    ENDIF.

    IF is_request-body IS INITIAL.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-parse_error
                                    iv_message = 'empty request body'
                                    iv_id_raw  = 'null' ).
      RETURN.
    ENDIF.

    IF strlen( is_request-body ) > zcl_akit_mcp_types=>gc_max_body_chars.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-invalid_request
                                    iv_message = 'request body too large'
                                    iv_id_raw  = 'null' ).
      RETURN.
    ENDIF.

    DATA(ls_req) = zcl_akit_mcp_json=>parse_request( is_request-body ).

    " A payload that produces neither jsonrpc nor method is not JSON at all.
    IF ls_req-jsonrpc IS INITIAL AND ls_req-method IS INITIAL.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-parse_error
                                    iv_message = 'invalid JSON request body'
                                    iv_id_raw  = 'null' ).
      RETURN.
    ENDIF.

    IF ls_req-jsonrpc <> `2.0`.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-invalid_request
                                    iv_message = 'missing or invalid jsonrpc version (expected "2.0")'
                                    iv_id_raw  = ls_req-id ).
      RETURN.
    ENDIF.

    IF ls_req-method IS INITIAL.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-invalid_request
                                    iv_message = 'missing JSON-RPC method'
                                    iv_id_raw  = ls_req-id ).
      RETURN.
    ENDIF.

    " A JSON-RPC notification carries no id: answer 202 and never a body.
    IF ls_req-id IS INITIAL.
      rs_response-status       = 202.
      rs_response-body         = ``.
      rs_response-content_type = ``.
      RETURN.
    ENDIF.

    " MCP forbids a null request id (only string / number ids are legal).
    IF ls_req-id = `null`.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-invalid_request
                                    iv_message = 'JSON-RPC id must not be null'
                                    iv_id_raw  = 'null' ).
      RETURN.
    ENDIF.

    " ----- era detection -----
    lv_meta_ver   = ls_req-params-meta-protocol_version.
    lv_header_ver = is_request-protocol_version.

    IF lv_header_ver IS NOT INITIAL AND lv_meta_ver IS NOT INITIAL
       AND lv_header_ver <> lv_meta_ver.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-header_mismatch
                                    iv_message = |header/body protocol version mismatch: { lv_header_ver } vs { lv_meta_ver }|
                                    iv_id_raw  = ls_req-id ).
      RETURN.
    ENDIF.

    IF lv_header_ver IS NOT INITIAL AND is_supported_version( lv_header_ver ) = abap_false.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-unsupported_protocol_version
                                    iv_message = |unsupported MCP-Protocol-Version: { lv_header_ver }|
                                    iv_id_raw  = ls_req-id
                                    iv_data_json = version_error_data( lv_header_ver ) ).
      RETURN.
    ENDIF.

    IF lv_meta_ver IS NOT INITIAL AND is_supported_version( lv_meta_ver ) = abap_false.
      rs_response = error_response( iv_status  = 400
                                    iv_code    = zcl_akit_mcp_types=>c_error-unsupported_protocol_version
                                    iv_message = |unsupported protocol version: { lv_meta_ver }|
                                    iv_id_raw  = ls_req-id
                                    iv_data_json = version_error_data( lv_meta_ver ) ).
      RETURN.
    ENDIF.

    " The modern era has no initialize handshake: any request that names a
    " modern version is dispatched as modern (and initialize/ping are not part
    " of the modern method set).
    IF lv_header_ver IS NOT INITIAL.
      lv_modern = is_modern_version( lv_header_ver ).
    ELSEIF lv_meta_ver IS NOT INITIAL.
      lv_modern = is_modern_version( lv_meta_ver ).
    ENDIF.

    IF lv_modern = abap_true.
      IF lv_meta_ver IS INITIAL.
        rs_response = error_response( iv_status  = 400
                                      iv_code    = zcl_akit_mcp_types=>c_error-invalid_params
                                      iv_message = 'modern requests require params._meta protocolVersion'
                                      iv_id_raw  = ls_req-id ).
        RETURN.
      ENDIF.
      IF lv_header_ver IS INITIAL.
        rs_response = error_response( iv_status  = 400
                                      iv_code    = zcl_akit_mcp_types=>c_error-header_mismatch
                                      iv_message = 'MCP-Protocol-Version header is required for modern requests'
                                      iv_id_raw  = ls_req-id ).
        RETURN.
      ENDIF.
      IF is_request-mcp_method IS INITIAL.
        rs_response = error_response( iv_status  = 400
                                      iv_code    = zcl_akit_mcp_types=>c_error-header_mismatch
                                      iv_message = 'Mcp-Method header is required for modern requests'
                                      iv_id_raw  = ls_req-id ).
        RETURN.
      ENDIF.
      IF is_request-mcp_method <> ls_req-method.
        rs_response = error_response( iv_status  = 400
                                      iv_code    = zcl_akit_mcp_types=>c_error-header_mismatch
                                      iv_message = 'Mcp-Method header does not match the JSON-RPC method'
                                      iv_id_raw  = ls_req-id ).
        RETURN.
      ENDIF.
      IF ls_req-method = `tools/call`.
        IF is_request-mcp_name IS INITIAL.
          rs_response = error_response( iv_status  = 400
                                        iv_code    = zcl_akit_mcp_types=>c_error-header_mismatch
                                        iv_message = 'Mcp-Name header is required for tools/call'
                                        iv_id_raw  = ls_req-id ).
          RETURN.
        ENDIF.
        IF ls_req-params-name <> is_request-mcp_name.
          rs_response = error_response( iv_status  = 400
                                        iv_code    = zcl_akit_mcp_types=>c_error-header_mismatch
                                        iv_message = 'Mcp-Name header does not match params.name'
                                        iv_id_raw  = ls_req-id ).
          RETURN.
        ENDIF.
      ENDIF.
      IF ls_req-params-meta-client_capabilities IS INITIAL.
        rs_response = error_response( iv_status  = 400
                                      iv_code    = zcl_akit_mcp_types=>c_error-invalid_params
                                      iv_message = 'modern requests require params._meta io.modelcontextprotocol/clientCapabilities'
                                      iv_id_raw  = ls_req-id ).
        RETURN.
      ENDIF.
    ENDIF.

    " ----- dispatch -----
    CASE ls_req-method.
      WHEN `initialize`.
        IF lv_modern = abap_true.
          rs_response = error_response( iv_status  = 404
                                        iv_code    = zcl_akit_mcp_types=>c_error-method_not_found
                                        iv_message = 'initialize is not part of the modern protocol era'
                                        iv_id_raw  = ls_req-id ).
          RETURN.
        ENDIF.
        IF ls_req-params-protocol_version IS INITIAL.
          rs_response = error_response( iv_status  = 200
                                        iv_code    = zcl_akit_mcp_types=>c_error-invalid_params
                                        iv_message = 'initialize requires params.protocolVersion'
                                        iv_id_raw  = ls_req-id ).
          RETURN.
        ENDIF.
        IF is_legacy_version( ls_req-params-protocol_version ) = abap_true.
          lv_payload = build_initialize( iv_endpoint         = lv_endpoint
                                         iv_protocol_version = ls_req-params-protocol_version ).
        ELSE.
          " Never fail a version negotiation: counter-offer the legacy baseline.
          lv_payload = build_initialize( iv_endpoint         = lv_endpoint
                                         iv_protocol_version = zcl_akit_mcp_types=>gc_protocol_legacy ).
        ENDIF.
        rs_response = result_response( iv_endpoint = lv_endpoint
                                       iv_payload  = lv_payload
                                       iv_id_raw   = ls_req-id
                                       iv_modern   = abap_false ).

      WHEN `ping`.
        IF lv_modern = abap_true.
          rs_response = error_response( iv_status  = 404
                                        iv_code    = zcl_akit_mcp_types=>c_error-method_not_found
                                        iv_message = 'ping is not part of the modern protocol era'
                                        iv_id_raw  = ls_req-id ).
        ELSE.
          rs_response = result_response( iv_endpoint = lv_endpoint
                                         iv_payload  = `{}`
                                         iv_id_raw   = ls_req-id
                                         iv_modern   = abap_false ).
        ENDIF.

      WHEN `tools/list`.
        lv_payload  = build_tools_list( lv_endpoint ).
        rs_response = result_response( iv_endpoint  = lv_endpoint
                                       iv_payload   = lv_payload
                                       iv_id_raw    = ls_req-id
                                       iv_modern    = lv_modern
                                       iv_cacheable = abap_true ).

      WHEN `tools/call`.
        build_tools_call( EXPORTING iv_endpoint   = lv_endpoint
                                    iv_params     = ls_req-params
                          IMPORTING ev_payload    = lv_payload
                                    ev_error_code = lv_error_code
                                    ev_error_text = lv_error_text ).
        IF lv_error_code <> 0.
          rs_response = error_response( iv_status  = 200
                                        iv_code    = lv_error_code
                                        iv_message = lv_error_text
                                        iv_id_raw  = ls_req-id ).
        ELSE.
          rs_response = result_response( iv_endpoint = lv_endpoint
                                         iv_payload  = lv_payload
                                         iv_id_raw   = ls_req-id
                                         iv_modern   = lv_modern ).
        ENDIF.

      WHEN `server/discover`.
        IF lv_modern = abap_true.
          lv_payload  = build_discover( lv_endpoint ).
          rs_response = result_response( iv_endpoint  = lv_endpoint
                                         iv_payload   = lv_payload
                                         iv_id_raw    = ls_req-id
                                         iv_modern    = abap_true
                                         iv_cacheable = abap_true ).
        ELSE.
          rs_response = error_response( iv_status  = 200
                                        iv_code    = zcl_akit_mcp_types=>c_error-method_not_found
                                        iv_message = |method not found: { ls_req-method }|
                                        iv_id_raw  = ls_req-id ).
        ENDIF.

      WHEN OTHERS.
        IF lv_modern = abap_true.
          rs_response = error_response( iv_status  = 404
                                        iv_code    = zcl_akit_mcp_types=>c_error-method_not_found
                                        iv_message = |method not found: { ls_req-method }|
                                        iv_id_raw  = ls_req-id ).
        ELSE.
          rs_response = error_response( iv_status  = 200
                                        iv_code    = zcl_akit_mcp_types=>c_error-method_not_found
                                        iv_message = |method not found: { ls_req-method }|
                                        iv_id_raw  = ls_req-id ).
        ENDIF.
    ENDCASE.
  ENDMETHOD.


  METHOD is_legacy_version.
    rv_legacy = boolc( iv_version = `2025-03-26`
                    OR iv_version = `2025-06-18`
                    OR iv_version = `2025-11-25` ).
  ENDMETHOD.


  METHOD is_modern_version.
    rv_modern = boolc( iv_version = zcl_akit_mcp_types=>gc_protocol_modern ).
  ENDMETHOD.


  METHOD is_supported_version.
    rv_supported = boolc( is_legacy_version( iv_version ) = abap_true
                       OR is_modern_version( iv_version ) = abap_true ).
  ENDMETHOD.


  METHOD build_root.
    DATA ls_result TYPE zcl_akit_mcp_types=>ty_root_result.

    ls_result-servers = zcl_akit_mcp_tools=>list_endpoints( ).
    ls_result-hint    = `POST /sap/bc/mcp/<endpoint> with MCP JSON-RPC `
                     && `(initialize, tools/list, tools/call).`.

    rv_body = zcl_akit_mcp_json=>to_json( ls_result ).
  ENDMETHOD.


  METHOD server_info.
    rs_info-name    = zcl_akit_mcp_types=>gc_server_name.
    rs_info-title   = zcl_akit_mcp_config=>title( iv_endpoint ).
    rs_info-version = zcl_akit_mcp_types=>gc_version.
  ENDMETHOD.


  METHOD instructions_text.
    rv_text = zcl_akit_mcp_config=>get( iv_server = iv_endpoint
                                        iv_name   = zcl_akit_mcp_types=>gc_conf_instructions ).
    IF rv_text IS INITIAL.
      rv_text = |AKIT MCP endpoint "{ to_lower( iv_endpoint ) }" exposes SAP ABAP tools over |
             && `the Model Context Protocol. Call tools/list to discover tools, then `
             && `tools/call with a JSON arguments object. Tools are read-only unless `
             && `the server configuration enables write tools.`.
    ENDIF.
  ENDMETHOD.


  METHOD build_initialize.
    DATA ls_result TYPE zcl_akit_mcp_types=>ty_initialize_result.

    ls_result-protocol_version                = iv_protocol_version.
    ls_result-capabilities-tools = `{}`.
    ls_result-server_info                     = server_info( iv_endpoint ).
    ls_result-instructions                    = instructions_text( iv_endpoint ).

    rv_payload = zcl_akit_mcp_json=>to_json_full( ls_result ).
  ENDMETHOD.


  METHOD build_tools_list.
    DATA lt_tools     TYPE zcl_akit_mcp_types=>ty_tools.
    DATA lt_defs      TYPE zcl_akit_mcp_types=>ty_tool_defs.
    DATA ls_def       TYPE zcl_akit_mcp_types=>ty_tool_def.
    DATA ls_result    TYPE zcl_akit_mcp_types=>ty_tools_list_result.
    DATA lv_read_only TYPE abap_bool.

    lv_read_only = zcl_akit_mcp_config=>read_only( iv_endpoint ).
    lt_tools     = zcl_akit_mcp_tools=>load( iv_endpoint ).

    LOOP AT lt_tools INTO DATA(ls_tool).
      IF lv_read_only = abap_true AND ls_tool-meta-write = abap_true.
        CONTINUE.
      ENDIF.

      CLEAR ls_def.
      ls_def-name                       = ls_tool-meta-name.
      ls_def-title                      = ls_tool-meta-title.
      ls_def-description                = ls_tool-meta-description.
      ls_def-input_schema                  = ls_tool-schema.
      ls_def-annotations-read_only_hint    = boolc( ls_tool-meta-write = abap_false ).
      ls_def-annotations-destructive_hint  = ls_tool-meta-write.
      ls_def-annotations-open_world_hint   = abap_false.
      APPEND ls_def TO lt_defs.
    ENDLOOP.

    ls_result-tools = lt_defs.
    rv_payload      = zcl_akit_mcp_json=>to_json_full( ls_result ).
  ENDMETHOD.


  METHOD build_tools_call.
    DATA lt_tools   TYPE zcl_akit_mcp_types=>ty_tools.
    DATA ls_found   TYPE zcl_akit_mcp_types=>ty_tool.
    DATA lv_found   TYPE abap_bool.
    DATA lv_args    TYPE string.
    DATA ls_result  TYPE zcl_akit_mcp_types=>ty_call_result.
    DATA lt_content TYPE zcl_akit_mcp_types=>ty_contents.
    DATA ls_content TYPE zcl_akit_mcp_types=>ty_content.

    ev_error_code = 0.
    ev_error_text = ``.

    IF iv_params-name IS INITIAL.
      ev_error_code = zcl_akit_mcp_types=>c_error-invalid_params.
      ev_error_text = 'tools/call requires params.name'.
      RETURN.
    ENDIF.

    lv_args = iv_params-arguments.
    IF lv_args IS INITIAL.
      lv_args = `{}`.
    ENDIF.

    lt_tools = zcl_akit_mcp_tools=>load( iv_endpoint ).
    LOOP AT lt_tools INTO DATA(ls_tool).
      IF ls_tool-meta-name = iv_params-name.
        ls_found = ls_tool.
        lv_found = abap_true.
        EXIT.
      ENDIF.
    ENDLOOP.

    IF lv_found = abap_false.
      ev_error_code = zcl_akit_mcp_types=>c_error-invalid_params.
      ev_error_text = |unknown tool: { iv_params-name }|.
      RETURN.
    ENDIF.

    " A read-only deployment hides and rejects write tools as if unknown.
    IF zcl_akit_mcp_config=>read_only( iv_endpoint ) = abap_true AND ls_found-meta-write = abap_true.
      ev_error_code = zcl_akit_mcp_types=>c_error-invalid_params.
      ev_error_text = |unknown tool: { iv_params-name }|.
      RETURN.
    ENDIF.

    ls_result = zcl_akit_mcp_tools=>execute( is_tool      = ls_found
                                             iv_arguments = lv_args ).

    ls_content-type = `text`.
    ls_content-text = ls_result-result_json.
    APPEND ls_content TO lt_content.

    IF ls_result-structured = abap_true AND ls_result-is_error = abap_false.
      DATA ls_structured TYPE zcl_akit_mcp_types=>ty_call_result_structured.
      ls_structured-content            = lt_content.
      ls_structured-structured_content = ls_result-result_json.
      ls_structured-is_error           = ls_result-is_error.
      ev_payload = zcl_akit_mcp_json=>to_json_full( ls_structured ).
    ELSE.
      DATA ls_plain TYPE zcl_akit_mcp_types=>ty_call_result_plain.
      ls_plain-content  = lt_content.
      ls_plain-is_error = ls_result-is_error.
      ev_payload = zcl_akit_mcp_json=>to_json_full( ls_plain ).
    ENDIF.
  ENDMETHOD.


  METHOD build_discover.
    DATA ls_result TYPE zcl_akit_mcp_types=>ty_discover_result.

    APPEND `2025-03-26` TO ls_result-supported_versions.
    APPEND `2025-06-18` TO ls_result-supported_versions.
    APPEND `2025-11-25` TO ls_result-supported_versions.
    APPEND `2026-07-28` TO ls_result-supported_versions.
    ls_result-capabilities-tools = `{}`.
    ls_result-instructions = instructions_text( iv_endpoint ).

    rv_payload = zcl_akit_mcp_json=>to_json_full( ls_result ).
  ENDMETHOD.


  METHOD result_response.
    DATA lv_json TYPE string.

    lv_json = iv_payload.
    IF iv_modern = abap_true.
      lv_json = zcl_akit_mcp_json=>merge_object(
        iv_base  = iv_payload
        iv_extra = modern_extras( iv_endpoint  = iv_endpoint
                                   iv_cacheable = iv_cacheable ) ).
    ENDIF.

    rs_response-status       = 200.
    rs_response-content_type = zcl_akit_mcp_types=>gc_content_type.
    rs_response-body = zcl_akit_mcp_json=>rpc_result( iv_id_raw      = iv_id_raw
                                                     iv_result_json = lv_json ).
  ENDMETHOD.


  METHOD error_response.
    rs_response-status       = iv_status.
    rs_response-content_type = zcl_akit_mcp_types=>gc_content_type.
    rs_response-body = zcl_akit_mcp_json=>rpc_error( iv_id_raw    = iv_id_raw
                                                    iv_code      = iv_code
                                                    iv_message   = iv_message
                                                    iv_data_json = iv_data_json ).
  ENDMETHOD.


  METHOD modern_extras.
    DATA ls_info TYPE zcl_akit_mcp_types=>ty_server_info.

    ls_info = server_info( iv_endpoint ).

    rv_extra = `"resultType":"complete"`.
    IF iv_cacheable = abap_true.
      rv_extra = rv_extra && `,"ttlMs":0,"cacheScope":"private"`.
    ENDIF.
    rv_extra = rv_extra && `,"_meta":{"io.modelcontextprotocol/serverInfo":`
                        && zcl_akit_mcp_json=>to_json( ls_info ) && `}`.
  ENDMETHOD.


  METHOD version_error_data.
    DATA lv_supported TYPE string.
    DATA lv_version   TYPE string.

    LOOP AT supported_versions( ) INTO lv_version.
      IF lv_supported IS NOT INITIAL.
        lv_supported = lv_supported && `,`.
      ENDIF.
      lv_supported = lv_supported && zcl_akit_mcp_json=>to_json( lv_version ).
    ENDLOOP.

    rv_json = `"supported":[` && lv_supported && `],"requested":`
           && zcl_akit_mcp_json=>to_json( iv_version ).
  ENDMETHOD.


  METHOD supported_versions.
    APPEND `2025-03-26` TO rt_versions.
    APPEND `2025-06-18` TO rt_versions.
    APPEND `2025-11-25` TO rt_versions.
    APPEND `2026-07-28` TO rt_versions.
  ENDMETHOD.

ENDCLASS.
