CLASS zcl_akit_mcp_tools DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    "! Load the enabled tools of one MCP endpoint (registry table
    "! ZTAKIT_MCP_TOOL). Rows whose class or metadata is broken are skipped, so
    "! one bad tool can never break the whole tools/list response.
    CLASS-METHODS load
      IMPORTING iv_server       TYPE string
      RETURNING VALUE(rt_tools) TYPE zcl_akit_mcp_types=>ty_tools.

    "! Endpoint catalogue for the ICF root path: every endpoint with at least
    "! one enabled tool, plus its title and tool count.
    CLASS-METHODS list_endpoints
      RETURNING VALUE(rt_endpoints) TYPE zcl_akit_mcp_types=>ty_endpoint_infos.

    "! Execute one tool. Never raises: ABAP/protocol problems are turned into an
    "! isError CallToolResult with a human readable message.
    CLASS-METHODS execute
      IMPORTING is_tool         TYPE zcl_akit_mcp_types=>ty_tool
                iv_arguments    TYPE string
      RETURNING VALUE(rs_result) TYPE zcl_akit_mcp_types=>ty_call_result.

    "! DDIC structure -> JSON Schema (flat fields, camelCase property names).
    "! Field descriptions come from the field label (@EndUserText.label, DD03T)
    "! or the field data element text (DD04T), in that order.
    CLASS-METHODS build_schema
      IMPORTING iv_struct_name   TYPE string
                it_required      TYPE zcl_akit_mcp_types=>ty_strings
      RETURNING VALUE(rv_schema) TYPE string.

    "! Input schema for one tool, honouring an optional GET_SCHEMA override.
    CLASS-METHODS build_input_schema
      IMPORTING iv_class_name    TYPE seoclsname
                is_meta          TYPE zcl_akit_mcp_types=>ty_tool_meta
      RETURNING VALUE(rv_schema) TYPE string.

    "! Validate one registry row (used by the setup report).
    CLASS-METHODS validate
      IMPORTING iv_class_name TYPE seoclsname
      EXPORTING es_meta       TYPE zcl_akit_mcp_types=>ty_tool_meta
                ev_ok         TYPE abap_bool
                ev_message    TYPE string.

  PRIVATE SECTION.
    CLASS-METHODS read_meta
      IMPORTING iv_class_name TYPE seoclsname
      EXPORTING es_meta       TYPE zcl_akit_mcp_types=>ty_tool_meta
                ev_ok         TYPE abap_bool
                ev_message    TYPE string.

    CLASS-METHODS schema_override
      IMPORTING iv_class_name    TYPE seoclsname
      RETURNING VALUE(rs_schema) TYPE zcl_akit_mcp_types=>ty_tool_schema.

    CLASS-METHODS execute_tool
      IMPORTING is_tool       TYPE zcl_akit_mcp_types=>ty_tool
                iv_arguments  TYPE string
      EXPORTING ev_result     TYPE string
                ev_error      TYPE abap_bool
                ev_message    TYPE string.

    CLASS-METHODS schema_property
      IMPORTING iv_struct_name  TYPE string
                iv_field_name   TYPE string
                io_type         TYPE REF TO cl_abap_datadescr
      RETURNING VALUE(rv_prop)  TYPE string.

    CLASS-METHODS field_text
      IMPORTING iv_struct_name TYPE string
                iv_field_name  TYPE string
                io_type        TYPE REF TO cl_abap_datadescr
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS json_scalar_type
      IMPORTING io_type        TYPE REF TO cl_abap_typedescr
      RETURNING VALUE(rv_type) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_tools IMPLEMENTATION.

  METHOD load.
    TYPES: BEGIN OF ty_reg_row,
             tool_class TYPE ztakit_mcp_tool-tool_class,
             tool_sort  TYPE ztakit_mcp_tool-tool_sort,
           END OF ty_reg_row,
           ty_reg_rows TYPE STANDARD TABLE OF ty_reg_row WITH DEFAULT KEY.

    DATA lt_rows  TYPE ty_reg_rows.
    DATA ls_row   TYPE ty_reg_row.
    DATA ls_meta  TYPE zcl_akit_mcp_types=>ty_tool_meta.
    DATA ls_tool  TYPE zcl_akit_mcp_types=>ty_tool.
    DATA lv_ok    TYPE abap_bool.
    DATA lv_msg   TYPE string.
    DATA lv_count TYPE i.
    DATA lv_server TYPE string.

    lv_server = to_lower( iv_server ).

    SELECT tool_class tool_sort FROM ztakit_mcp_tool INTO TABLE lt_rows
      WHERE server = lv_server AND tool_enabled = 'X'
      ORDER BY tool_sort ASCENDING tool_class ASCENDING.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    LOOP AT lt_rows INTO ls_row.
      lv_count = lv_count + 1.
      IF lv_count > zcl_akit_mcp_types=>gc_max_load_rows.
        EXIT.
      ENDIF.

      read_meta( EXPORTING iv_class_name = ls_row-tool_class
                 IMPORTING es_meta       = ls_meta
                           ev_ok         = lv_ok
                           ev_message    = lv_msg ).
      IF lv_ok = abap_false.
        CONTINUE.
      ENDIF.

      CLEAR ls_tool.
      ls_tool-class_name = ls_row-tool_class.
      ls_tool-sort       = ls_row-tool_sort.
      ls_tool-meta       = ls_meta.

      ls_tool-schema = build_input_schema( iv_class_name = ls_row-tool_class
                                           is_meta       = ls_meta ).

      APPEND ls_tool TO rt_tools.
    ENDLOOP.
  ENDMETHOD.


  METHOD list_endpoints.
    TYPES: BEGIN OF ty_server_row,
             server TYPE ztakit_mcp_tool-server,
           END OF ty_server_row,
           ty_server_rows TYPE STANDARD TABLE OF ty_server_row WITH DEFAULT KEY.

    DATA lt_servers  TYPE ty_server_rows.
    DATA lv_server   TYPE string.
    DATA lv_last     TYPE string.
    DATA ls_endpoint TYPE zcl_akit_mcp_types=>ty_endpoint_info.

    SELECT server FROM ztakit_mcp_tool INTO TABLE lt_servers
      WHERE tool_enabled = 'X'
      ORDER BY server ASCENDING.

    LOOP AT lt_servers INTO DATA(ls_row).
      IF ls_row-server IS INITIAL OR ls_row-server = lv_last.
        CONTINUE.
      ENDIF.
      lv_last = ls_row-server.

      lv_server = ls_row-server.

      CLEAR ls_endpoint.
      ls_endpoint-name  = lv_server.
      ls_endpoint-title = zcl_akit_mcp_config=>title( lv_server ).

      LOOP AT lt_servers INTO DATA(ls_count) WHERE server = ls_row-server.
        ls_endpoint-tools = ls_endpoint-tools + 1.
      ENDLOOP.

      APPEND ls_endpoint TO rt_endpoints.
    ENDLOOP.
  ENDMETHOD.


  METHOD read_meta.
    DATA lv_class  TYPE string.
    DATA lv_method TYPE string.

    ev_ok      = abap_false.
    ev_message = ``.

    DATA lv_dummy TYPE string.

    " A dynamic CALL METHOD with an unknown class triggers the non-catchable
    " runtime error TYPE_NOT_FOUND on some releases, so check TADIR first.
    SELECT SINGLE object FROM tadir INTO lv_dummy
      WHERE pgmid = 'R3TR' AND object = 'CLAS' AND obj_name = iv_class_name.
    IF sy-subrc <> 0.
      ev_message = |{ iv_class_name } not found (TADIR)|.
      RETURN.
    ENDIF.

    TRY.
        lv_class  = iv_class_name.
        lv_method = zcl_akit_mcp_types=>gc_method_meta.

        CALL METHOD (lv_class)=>(lv_method)
          RECEIVING rs_meta = es_meta.

        es_meta-name = to_lower( es_meta-name ).
        IF es_meta-name IS INITIAL.
          ev_message = 'GET_META returned an empty tool name'.
          RETURN.
        ENDIF.

        ev_ok = abap_true.

      CATCH cx_root INTO DATA(lx).
        ev_message = condense( lx->get_text( ) ).
        IF ev_message IS INITIAL.
          ev_message = |{ iv_class_name }: GET_META is missing or has an incompatible signature|.
        ENDIF.
    ENDTRY.
  ENDMETHOD.


  METHOD execute.
    DATA lv_result TYPE string.
    DATA lv_error  TYPE abap_bool.
    DATA lv_msg    TYPE string.

    rs_result-is_error   = abap_false.
    rs_result-structured = abap_false.

    IF zcl_akit_mcp_json=>is_json_object( iv_arguments ) = abap_false.
      rs_result-is_error    = abap_true.
      rs_result-result_json = 'tool arguments must be a JSON object'.
      RETURN.
    ENDIF.

    execute_tool( EXPORTING is_tool      = is_tool
                            iv_arguments = iv_arguments
                  IMPORTING ev_result    = lv_result
                            ev_error     = lv_error
                            ev_message   = lv_msg ).

    IF lv_error = abap_true.
      rs_result-is_error    = abap_true.
      rs_result-result_json = lv_msg.
      RETURN.
    ENDIF.

    rs_result-result_json = lv_result.
    rs_result-structured  = zcl_akit_mcp_json=>is_json_object( lv_result ).
  ENDMETHOD.


  METHOD execute_tool.
    DATA lv_class  TYPE string.
    DATA lv_method TYPE string.
    DATA lv_result TYPE string.
    DATA lv_struct TYPE string.
    DATA lr_args   TYPE REF TO data.

    ev_error   = abap_false.
    ev_message = ``.
    ev_result  = ``.

    lv_class  = is_tool-class_name.
    lv_method = zcl_akit_mcp_types=>gc_method_execute.

    TRY.
        IF is_tool-meta-raw_args = abap_true.
          CALL METHOD (lv_class)=>(lv_method)
            EXPORTING iv_args   = iv_arguments
            RECEIVING rv_result = lv_result.

        ELSEIF is_tool-meta-args_struct IS NOT INITIAL.
          lv_struct = is_tool-meta-args_struct.
          CREATE DATA lr_args TYPE (lv_struct).
          ASSIGN lr_args->* TO FIELD-SYMBOL(<ls_args>).

          /ui2/cl_json=>deserialize(
            EXPORTING json        = iv_arguments
                      pretty_name = /ui2/cl_json=>pretty_mode-camel_case
            CHANGING  data        = <ls_args> ).

          CALL METHOD (lv_class)=>(lv_method)
            EXPORTING is_args   = <ls_args>
            RECEIVING rv_result = lv_result.

        ELSE.
          CALL METHOD (lv_class)=>(lv_method)
            RECEIVING rv_result = lv_result.
        ENDIF.

        ev_result = lv_result.

      CATCH zcx_akit_mcp_tool_error INTO DATA(lx_tool).
        ev_error   = abap_true.
        ev_message = lx_tool->get_error_text( ).
      CATCH zcx_akit_mcp_error INTO DATA(lx_akit).
        ev_error   = abap_true.
        ev_message = lx_akit->get_error_text( ).
      CATCH cx_root INTO DATA(lx).
        ev_error   = abap_true.
        ev_message = condense( lx->get_text( ) ).
        IF ev_message IS INITIAL.
          ev_message = |tool { is_tool-meta-name } failed|.
        ENDIF.
    ENDTRY.
  ENDMETHOD.


  METHOD build_input_schema.
    DATA ls_override TYPE zcl_akit_mcp_types=>ty_tool_schema.
    DATA lv_mode     TYPE char1.
    DATA lv_struct   TYPE string.
    DATA lv_schema   TYPE string.

    lv_mode   = zcl_akit_mcp_types=>gc_schema_auto.
    lv_struct = is_meta-args_struct.
    lv_schema = is_meta-raw_schema.

    IF is_meta-raw_args = abap_true AND lv_schema IS NOT INITIAL.
      " Legacy flag: the class already ships its own schema text.
      lv_mode = zcl_akit_mcp_types=>gc_schema_manual.
    ENDIF.

    ls_override = schema_override( iv_class_name = iv_class_name ).
    IF ls_override-mode IS NOT INITIAL.
      lv_mode = ls_override-mode.
      IF ls_override-struct_name IS NOT INITIAL.
        lv_struct = ls_override-struct_name.
      ENDIF.
      IF ls_override-schema IS NOT INITIAL.
        lv_schema = ls_override-schema.
      ENDIF.
    ENDIF.

    CASE lv_mode.
      WHEN zcl_akit_mcp_types=>gc_schema_manual.
        IF zcl_akit_mcp_json=>is_json_object( lv_schema ).
          rv_schema = lv_schema.
        ELSE.
          rv_schema = `{"type":"object","properties":{}}`.
        ENDIF.
      WHEN zcl_akit_mcp_types=>gc_schema_none.
        rv_schema = `{"type":"object","properties":{}}`.
      WHEN OTHERS.
        rv_schema = build_schema( iv_struct_name = lv_struct
                                  it_required    = is_meta-required ).
    ENDCASE.
  ENDMETHOD.


  METHOD schema_override.
    DATA lv_method TYPE string.
    DATA ls_schema TYPE zcl_akit_mcp_types=>ty_tool_schema.

    " A dynamic call on a missing class dumps, so check the repository first.
    SELECT SINGLE object FROM tadir INTO @DATA(lv_object)
      WHERE pgmid = 'R3TR' AND object = 'CLAS' AND obj_name = @iv_class_name.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    lv_method = zcl_akit_mcp_types=>gc_method_get_schema.

    TRY.
        CALL METHOD (iv_class_name)=>(lv_method)
          RECEIVING rs_schema = ls_schema.
        rs_schema = ls_schema.
      CATCH cx_sy_dyn_call_illegal_method.
        " Optional method not implemented: keep the automatic schema.
      CATCH cx_root.
        " A broken override must never break tools/list: fall back to auto.
    ENDTRY.
  ENDMETHOD.


  METHOD build_schema.
    DATA lv_props    TYPE string.
    DATA lv_required TYPE string.
    DATA lv_prop     TYPE string.
    DATA lv_name     TYPE string.
    DATA lv_req_name TYPE string.

    IF iv_struct_name IS INITIAL.
      rv_schema = `{"type":"object","properties":{}}`.
      RETURN.
    ENDIF.

    " RTTI describe_by_name on a missing type is a non-catchable dump.
    SELECT SINGLE tabname FROM dd03l INTO @DATA(lv_tabname)
      WHERE tabname = @iv_struct_name.
    IF sy-subrc <> 0.
      rv_schema = `{"type":"object","properties":{}}`.
      RETURN.
    ENDIF.

    TRY.
        DATA(lo_descr) = cl_abap_typedescr=>describe_by_name( iv_struct_name ).
      CATCH cx_root.
        rv_schema = `{"type":"object","properties":{}}`.
        RETURN.
    ENDTRY.

    IF lo_descr IS NOT INSTANCE OF cl_abap_structdescr.
      rv_schema = `{"type":"object","properties":{}}`.
      RETURN.
    ENDIF.

    DATA(lo_struc) = CAST cl_abap_structdescr( lo_descr ).
    DATA(lt_components) = lo_struc->get_components( ).

    LOOP AT lt_components INTO DATA(ls_component).
      IF ls_component-type IS NOT INSTANCE OF cl_abap_datadescr.
        CONTINUE.
      ENDIF.

      lv_prop = schema_property( iv_struct_name = iv_struct_name
                                 iv_field_name  = ls_component-name
                                 io_type        = CAST cl_abap_datadescr( ls_component-type ) ).
      lv_name = zcl_akit_mcp_json=>to_camel( ls_component-name ).
      IF lv_props IS NOT INITIAL.
        lv_props = lv_props && `,`.
      ENDIF.
      lv_props = lv_props && zcl_akit_mcp_json=>to_json( lv_name ) && `:` && lv_prop.
    ENDLOOP.

    LOOP AT it_required INTO DATA(lv_req).
      lv_req_name = zcl_akit_mcp_json=>to_camel( lv_req ).
      IF lv_required IS NOT INITIAL.
        lv_required = lv_required && `,`.
      ENDIF.
      lv_required = lv_required && zcl_akit_mcp_json=>to_json( lv_req_name ).
    ENDLOOP.

    rv_schema = `{"type":"object","properties":{` && lv_props && `}`.
    IF lv_required IS NOT INITIAL.
      rv_schema = rv_schema && `,"required":[` && lv_required && `]`.
    ENDIF.
    rv_schema = rv_schema && `,"additionalProperties":false}`.
  ENDMETHOD.


  METHOD schema_property.
    DATA lv_type TYPE string.
    DATA lv_text TYPE string.

    IF io_type IS INSTANCE OF cl_abap_elemdescr.
      lv_type = json_scalar_type( io_type ).
    ELSEIF io_type IS INSTANCE OF cl_abap_structdescr.
      " Nested types are not derived field by field in v1: pass the object
      " through (or use raw_args mode for a hand-written schema).
      lv_type = `object`.
    ELSEIF io_type IS INSTANCE OF cl_abap_tabledescr.
      lv_type = `array`.
    ELSE.
      lv_type = `string`.
    ENDIF.

    lv_text = field_text( iv_struct_name = iv_struct_name
                          iv_field_name  = iv_field_name
                          io_type        = io_type ).

    rv_prop = `{"type":` && zcl_akit_mcp_json=>to_json( lv_type ).
    IF lv_text IS NOT INITIAL.
      rv_prop = rv_prop && `,"description":` && zcl_akit_mcp_json=>to_json( lv_text ).
    ENDIF.
    rv_prop = rv_prop && `}`.
  ENDMETHOD.


  METHOD field_text.
    DATA lv_rollname TYPE rollname.
    DATA lv_langu    TYPE sylangu.

    lv_langu = sy-langu.

    " 1) data element text (DD04T)
    IF io_type IS INSTANCE OF cl_abap_elemdescr.
      DATA(lo_elem) = CAST cl_abap_elemdescr( io_type ).
      TRY.
          IF lo_elem->is_ddic_type( ) = abap_true.
            lo_elem->get_ddic_field( RECEIVING p_flddescr = DATA(ls_dfies) ).
            lv_rollname = ls_dfies-rollname.
          ENDIF.
        CATCH cx_root.
          CLEAR lv_rollname.
      ENDTRY.
    ENDIF.

    IF lv_rollname IS NOT INITIAL.
      SELECT SINGLE ddtext FROM dd04t INTO rv_text
        WHERE rollname = lv_rollname AND ddlanguage = lv_langu.
      IF sy-subrc <> 0.
        SELECT SINGLE ddtext FROM dd04t INTO rv_text
          WHERE rollname = lv_rollname AND ddlanguage = 'E'.
      ENDIF.
    ENDIF.

    " 2) field label of inline-typed fields (@EndUserText.label -> DD03T)
    IF rv_text IS INITIAL AND iv_struct_name IS NOT INITIAL.
      SELECT SINGLE ddtext FROM dd03t INTO rv_text
        WHERE tabname = iv_struct_name AND fieldname = iv_field_name AND ddlanguage = lv_langu.
      IF sy-subrc <> 0.
        SELECT SINGLE ddtext FROM dd03t INTO rv_text
          WHERE tabname = iv_struct_name AND fieldname = iv_field_name AND ddlanguage = 'E'.
      ENDIF.
    ENDIF.

    " 3) last resort: human readable field name
    IF rv_text IS INITIAL.
      rv_text = zcl_akit_mcp_json=>humanize( iv_field_name ).
    ENDIF.
  ENDMETHOD.


  METHOD json_scalar_type.
    CASE io_type->type_kind.
      WHEN cl_abap_typedescr=>typekind_int
        OR cl_abap_typedescr=>typekind_int8.
        rv_type = `integer`.
      WHEN cl_abap_typedescr=>typekind_packed
        OR cl_abap_typedescr=>typekind_float
        OR cl_abap_typedescr=>typekind_decfloat
        OR cl_abap_typedescr=>typekind_decfloat16
        OR cl_abap_typedescr=>typekind_decfloat34.
        rv_type = `number`.
      WHEN OTHERS.
        rv_type = `string`.
    ENDCASE.
  ENDMETHOD.


  METHOD validate.
    ev_ok = abap_false.

    read_meta( EXPORTING iv_class_name = iv_class_name
               IMPORTING es_meta       = es_meta
                         ev_ok         = ev_ok
                         ev_message    = ev_message ).
    IF ev_ok = abap_false.
      RETURN.
    ENDIF.

    IF es_meta-raw_args = abap_false AND es_meta-args_struct IS NOT INITIAL.
      SELECT SINGLE tabname FROM dd03l INTO @DATA(lv_tabname)
        WHERE tabname = @es_meta-args_struct.
      IF sy-subrc <> 0.
        ev_ok      = abap_false.
        ev_message = |arguments structure { es_meta-args_struct } not found|.
        RETURN.
      ENDIF.
      TRY.
          DATA(lo_descr) = cl_abap_typedescr=>describe_by_name( es_meta-args_struct ).
          IF lo_descr IS NOT INSTANCE OF cl_abap_structdescr.
            ev_ok      = abap_false.
            ev_message = |arguments type { es_meta-args_struct } is not a structure|.
            RETURN.
          ENDIF.
        CATCH cx_root.
          ev_ok      = abap_false.
          ev_message = |arguments structure { es_meta-args_struct } not found|.
          RETURN.
      ENDTRY.
    ENDIF.

    ev_ok = abap_true.
  ENDMETHOD.

ENDCLASS.
