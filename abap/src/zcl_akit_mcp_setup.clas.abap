CLASS zcl_akit_mcp_setup DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

  PRIVATE SECTION.
    TYPES:
      BEGIN OF ty_seed,
        class_name TYPE seoclsname,
        sort       TYPE i,
      END OF ty_seed,
      ty_seeds TYPE STANDARD TABLE OF ty_seed WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_report,
        status   TYPE string,
        endpoint TYPE string,
        url      TYPE string,
        tools    TYPE i,
        added    TYPE i,
        invalid  TYPE zcl_akit_mcp_types=>ty_strings,
      END OF ty_report.

    CLASS-METHODS run
      RETURNING VALUE(rv_json) TYPE string.

    CLASS-METHODS builtin_tools
      RETURNING VALUE(rt_seeds) TYPE ty_seeds.
ENDCLASS.


CLASS zcl_akit_mcp_setup IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.
    out->write( run( ) ).
  ENDMETHOD.


  METHOD run.
    DATA lt_seeds    TYPE ty_seeds.
    DATA lt_existing TYPE STANDARD TABLE OF ztakit_mcp_tool.
    DATA ls_row      TYPE ztakit_mcp_tool.
    DATA ls_report   TYPE ty_report.
    DATA ls_meta     TYPE zcl_akit_mcp_types=>ty_tool_meta.
    DATA ls_conf     TYPE ztakit_mcp_conf.
    DATA lv_endpoint TYPE string.
    DATA lv_ok       TYPE abap_bool.
    DATA lv_msg      TYPE string.

    lv_endpoint = zcl_akit_mcp_types=>gc_default_endpoint.
    lt_seeds    = builtin_tools( ).

    " Make the default endpoint addressable even before any tool is installed:
    " the endpoint exists as soon as it has one registry or configuration row.
    SELECT SINGLE conf_value FROM ztakit_mcp_conf INTO lv_msg
      WHERE server = lv_endpoint AND conf_name = zcl_akit_mcp_types=>gc_conf_title.
    IF sy-subrc <> 0.
      CLEAR ls_conf.
      ls_conf-server     = lv_endpoint.
      ls_conf-conf_name  = zcl_akit_mcp_types=>gc_conf_title.
      ls_conf-conf_value = |{ zcl_akit_mcp_types=>gc_server_title } - { lv_endpoint } tools|.
      INSERT ztakit_mcp_conf FROM ls_conf.
    ENDIF.

    " Seed the built-in toolkit into the default endpoint. Idempotent: an
    " existing row is never overwritten, so local enable/disable and sort
    " changes survive an upgrade.
    SELECT * FROM ztakit_mcp_tool INTO TABLE lt_existing WHERE server = lv_endpoint.

    LOOP AT lt_seeds INTO DATA(ls_seed).
      READ TABLE lt_existing TRANSPORTING NO FIELDS WITH KEY tool_class = ls_seed-class_name.
      IF sy-subrc = 0.
        CONTINUE.
      ENDIF.

      " Do not register a tool class that is not installed yet (or is broken).
      zcl_akit_mcp_tools=>validate( EXPORTING iv_class_name = ls_seed-class_name
                                    IMPORTING es_meta       = ls_meta
                                              ev_ok         = lv_ok
                                              ev_message    = lv_msg ).
      IF lv_ok = abap_false.
        CONTINUE.
      ENDIF.

      CLEAR ls_row.
      ls_row-server       = lv_endpoint.
      ls_row-tool_class   = ls_seed-class_name.
      ls_row-tool_enabled = 'X'.
      ls_row-tool_sort    = ls_seed-sort.
      INSERT ztakit_mcp_tool FROM ls_row.
      IF sy-subrc = 0.
        ls_report-added = ls_report-added + 1.
      ENDIF.
    ENDLOOP.

    " Validate every registry row of the endpoint, including custom tools.
    SELECT * FROM ztakit_mcp_tool INTO TABLE lt_existing WHERE server = lv_endpoint.

    LOOP AT lt_existing INTO ls_row.
      zcl_akit_mcp_tools=>validate( EXPORTING iv_class_name = ls_row-tool_class
                                    IMPORTING es_meta       = ls_meta
                                              ev_ok         = lv_ok
                                              ev_message    = lv_msg ).
      IF lv_ok = abap_true.
        ls_report-tools = ls_report-tools + 1.
      ELSE.
        APPEND |{ ls_row-tool_class }: { lv_msg }| TO ls_report-invalid.
      ENDIF.
    ENDLOOP.

    ls_report-status   = `ok`.
    ls_report-endpoint = lv_endpoint.
    ls_report-url      = |{ zcl_akit_mcp_types=>gc_icf_path }/{ lv_endpoint }|.

    rv_json = zcl_akit_mcp_json=>to_json( ls_report ).
  ENDMETHOD.


  METHOD builtin_tools.
    rt_seeds = VALUE #(
      ( class_name = 'ZCL_AKIT_MCP_TOOL_SYSINFO'       sort = 10 )
      ( class_name = 'ZCL_AKIT_MCP_TOOL_OBJ_SEARCH'    sort = 20 )
      ( class_name = 'ZCL_AKIT_MCP_TOOL_SOURCE_READ'   sort = 30 )
      ( class_name = 'ZCL_AKIT_MCP_TOOL_SYNTAX_CHECK'  sort = 40 )
      ( class_name = 'ZCL_AKIT_MCP_TOOL_DDIC_GET'      sort = 50 )
      ( class_name = 'ZCL_AKIT_MCP_TOOL_TABLE_READ'    sort = 60 )
      ( class_name = 'ZCL_AKIT_MCP_TOOL_TCODE_INFO'    sort = 70 )
      ( class_name = 'ZCL_AKIT_MCP_TOOL_MESSAGE_TEXT'  sort = 80 )
    ).
  ENDMETHOD.

ENDCLASS.
