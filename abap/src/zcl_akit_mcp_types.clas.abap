CLASS zcl_akit_mcp_types DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    " ----- registry / tool contract -----
    TYPES ty_strings TYPE STANDARD TABLE OF string WITH DEFAULT KEY.

    "! Metadata every tool class returns from its static GET_META method:
    "!   CLASS-METHODS get_meta
    "!     RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.
    TYPES:
      BEGIN OF ty_tool_meta,
        name        TYPE string,
        title       TYPE string,
        description TYPE string,
        args_struct TYPE string,
        required    TYPE ty_strings,
        write       TYPE abap_bool,
        raw_args    TYPE abap_bool,
        raw_schema  TYPE string,
      END OF ty_tool_meta.

    "! One registered tool: registry row + metadata + generated input schema.
    TYPES:
      BEGIN OF ty_tool,
        class_name TYPE seoclsname,
        sort       TYPE i,
        meta       TYPE ty_tool_meta,
        schema     TYPE string,
      END OF ty_tool.

    TYPES ty_tools TYPE STANDARD TABLE OF ty_tool WITH DEFAULT KEY.

    "! Optional schema override returned by a tool class' GET_SCHEMA method.
    "! mode = A: derive from DDIC (struct_name may override args_struct)
    "!        M: use schema (JSON Schema object text)
    "!        N: no parameters
    TYPES:
      BEGIN OF ty_tool_schema,
        mode        TYPE char1,
        struct_name TYPE string,
        schema      TYPE string,
      END OF ty_tool_schema.

    TYPES:
      BEGIN OF ty_call_result,
        result_json TYPE string,
        is_error    TYPE abap_bool,
        structured  TYPE abap_bool,
      END OF ty_call_result.

    " ----- HTTP abstraction -----
    TYPES:
      BEGIN OF ty_request,
        endpoint         TYPE string,
        body             TYPE string,
        protocol_version TYPE string,
        mcp_method       TYPE string,
        mcp_name         TYPE string,
        origin           TYPE string,
      END OF ty_request.

    TYPES:
      BEGIN OF ty_response,
        status        TYPE i,
        body          TYPE string,
        content_type  TYPE string,
        allow         TYPE string,
        extra_headers TYPE ty_strings,
      END OF ty_response.

    " ----- JSON-RPC request (deserialized with /UI2/CL_JSON) -----
    "! Per-request `_meta` (modern protocol era). The JSON member name is
    "! `_meta`, mapped via name mappings in ZCL_AKIT_MCP_JSON.
    TYPES:
      BEGIN OF ty_meta,
        protocol_version    TYPE string,
        client_info         TYPE /ui2/cl_json=>json,
        client_capabilities TYPE /ui2/cl_json=>json,
        log_level           TYPE string,
      END OF ty_meta.

    "! Union of all params members used by the supported methods. Arguments
    "! keep their raw JSON text so they can be deserialized into the tool's
    "! DDIC argument structure.
    TYPES:
      BEGIN OF ty_params,
        protocol_version TYPE string,
        capabilities     TYPE /ui2/cl_json=>json,
        client_info      TYPE /ui2/cl_json=>json,
        cursor           TYPE string,
        name             TYPE string,
        arguments        TYPE /ui2/cl_json=>json,
        meta             TYPE ty_meta,
      END OF ty_params.

    TYPES:
      BEGIN OF ty_rpc_request,
        jsonrpc TYPE string,
        id      TYPE /ui2/cl_json=>json,
        method  TYPE string,
        params  TYPE ty_params,
      END OF ty_rpc_request.

    " ----- protocol results (serialized with /UI2/CL_JSON camelCase) -----
    TYPES:
      BEGIN OF ty_server_info,
        name    TYPE string,
        title   TYPE string,
        version TYPE string,
      END OF ty_server_info.

    "! MCP capabilities: only the tools capability is advertised. An empty
    "! capability object is spec-compliant and avoids the listChanged contract.
    TYPES:
      BEGIN OF ty_capabilities,
        tools TYPE /ui2/cl_json=>json,
      END OF ty_capabilities.

    TYPES:
      BEGIN OF ty_initialize_result,
        protocol_version TYPE string,
        capabilities     TYPE ty_capabilities,
        server_info      TYPE ty_server_info,
        instructions     TYPE string,
      END OF ty_initialize_result.

    "! Tool annotations: emitted explicitly because the protocol defaults
    "! (destructiveHint/openWorldHint = true) are wrong for read-only tools.
    TYPES:
      BEGIN OF ty_annotations,
        read_only_hint   TYPE abap_bool,
        destructive_hint TYPE abap_bool,
        open_world_hint  TYPE abap_bool,
      END OF ty_annotations.

    TYPES:
      BEGIN OF ty_tool_def,
        name         TYPE string,
        title        TYPE string,
        description  TYPE string,
        input_schema TYPE /ui2/cl_json=>json,
        annotations  TYPE ty_annotations,
      END OF ty_tool_def,
      ty_tool_defs TYPE STANDARD TABLE OF ty_tool_def WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_tools_list_result,
        tools TYPE ty_tool_defs,
      END OF ty_tools_list_result.

    TYPES:
      BEGIN OF ty_content,
        type TYPE string,
        text TYPE string,
      END OF ty_content,
      ty_contents TYPE STANDARD TABLE OF ty_content WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_call_result_plain,
        content  TYPE ty_contents,
        is_error TYPE abap_bool,
      END OF ty_call_result_plain.

    TYPES:
      BEGIN OF ty_call_result_structured,
        content            TYPE ty_contents,
        structured_content TYPE /ui2/cl_json=>json,
        is_error           TYPE abap_bool,
      END OF ty_call_result_structured.

    TYPES:
      BEGIN OF ty_discover_result,
        supported_versions TYPE ty_strings,
        capabilities       TYPE ty_capabilities,
        instructions       TYPE string,
      END OF ty_discover_result.

    TYPES:
      BEGIN OF ty_error_object,
        code    TYPE i,
        message TYPE string,
      END OF ty_error_object.

    "! Envelope fields stamped on every modern-era result.
    TYPES:
      BEGIN OF ty_result_meta,
        server_info TYPE ty_server_info,
      END OF ty_result_meta.

    TYPES:
      BEGIN OF ty_modern_extras,
        result_type TYPE string,
        ttl_ms      TYPE i,
        cache_scope TYPE string,
        meta        TYPE ty_result_meta,
      END OF ty_modern_extras.

    " ----- endpoint catalogue (root discovery) -----
    TYPES:
      BEGIN OF ty_endpoint_info,
        name  TYPE string,
        title TYPE string,
        tools TYPE i,
      END OF ty_endpoint_info,
      ty_endpoint_infos TYPE STANDARD TABLE OF ty_endpoint_info WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_root_result,
        servers TYPE ty_endpoint_infos,
        hint    TYPE string,
      END OF ty_root_result.

    " ----- constants -----
    CONSTANTS:
      BEGIN OF c_error,
        parse_error                 TYPE i VALUE -32700,
        invalid_request             TYPE i VALUE -32600,
        method_not_found            TYPE i VALUE -32601,
        invalid_params              TYPE i VALUE -32602,
        internal_error              TYPE i VALUE -32603,
        header_mismatch             TYPE i VALUE -32020,
        missing_client_capability   TYPE i VALUE -32021,
        unsupported_protocol_version TYPE i VALUE -32022,
      END OF c_error.

    CONSTANTS:
      gc_server_name       TYPE string VALUE 'akit-mcp',
      gc_server_title      TYPE string VALUE 'AKIT MCP',
      gc_version           TYPE string VALUE '1.0.0',
      gc_icf_path          TYPE string VALUE '/sap/bc/mcp',
      gc_server_global     TYPE string VALUE '*',
      gc_default_endpoint  TYPE string VALUE 'dev',
      gc_content_type      TYPE string VALUE 'application/json; charset=utf-8',
      " Legacy versions share the 2025-11-25 wire shapes; modern is the
      " stateless 2026-07-28 request/response profile.
      gc_protocol_legacy   TYPE string VALUE '2025-11-25',
      gc_protocol_modern   TYPE string VALUE '2026-07-28',
      " Fixed tool method / parameter names (the dynamic call contract).
      gc_method_meta       TYPE string VALUE 'GET_META',
      gc_method_execute    TYPE string VALUE 'EXECUTE',
      " Optional: let the tool class choose its input schema source.
      gc_method_get_schema TYPE string VALUE 'GET_SCHEMA',
      gc_schema_auto       TYPE char1 VALUE 'A',
      gc_schema_manual     TYPE char1 VALUE 'M',
      gc_schema_none       TYPE char1 VALUE 'N',
      gc_param_meta        TYPE string VALUE 'RS_META',
      gc_param_args        TYPE string VALUE 'IS_ARGS',
      gc_param_raw_args    TYPE string VALUE 'IV_ARGS',
      gc_param_result      TYPE string VALUE 'RV_RESULT',
      " Configuration keys (table ZTAKIT_MCP_CONF).
      gc_conf_enabled      TYPE string VALUE 'ENABLED',
      gc_conf_title        TYPE string VALUE 'TITLE',
      gc_conf_read_only    TYPE string VALUE 'READ_ONLY',
      gc_conf_max_rows     TYPE string VALUE 'MAX_ROWS',
      gc_conf_origins      TYPE string VALUE 'ORIGINS',
      gc_conf_instructions TYPE string VALUE 'INSTRUCTIONS',
      " Limits.
      gc_max_rows_hard     TYPE i VALUE 5000,
      gc_max_body_chars    TYPE i VALUE 1048576,
      gc_max_load_rows     TYPE i VALUE 500.
ENDCLASS.


CLASS zcl_akit_mcp_types IMPLEMENTATION.
ENDCLASS.
