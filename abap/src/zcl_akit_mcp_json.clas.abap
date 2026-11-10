CLASS zcl_akit_mcp_json DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    "! Serialize ABAP data to compact camelCase JSON via /UI2/CL_JSON.
    "! Initial values are omitted (compact business data).
    CLASS-METHODS to_json
      IMPORTING iv_data        TYPE data
      RETURNING VALUE(rv_json) TYPE string.

    "! Serialize protocol payloads: initial values are kept, so empty arrays
    "! (e.g. tools) and explicit false annotations stay on the wire.
    CLASS-METHODS to_json_full
      IMPORTING iv_data        TYPE data
      RETURNING VALUE(rv_json) TYPE string.

    "! Raw JSON text of one top-level member of a JSON object ('' when absent).
    "! Used to extract params._meta and tool arguments without a JSON tree.
    CLASS-METHODS extract_member
      IMPORTING iv_json        TYPE string
                iv_name        TYPE string
      RETURNING VALUE(rv_raw)  TYPE string.

    "! Deserialize a JSON-RPC request body. Returns an empty structure when the
    "! payload is not valid JSON (the caller maps that to -32700).
    CLASS-METHODS parse_request
      IMPORTING iv_body           TYPE string
      RETURNING VALUE(rs_request) TYPE zcl_akit_mcp_types=>ty_rpc_request.

    "! JSON-RPC success envelope: {"jsonrpc":"2.0","id":<raw>,"result":<json>}.
    CLASS-METHODS rpc_result
      IMPORTING iv_id_raw      TYPE string
                iv_result_json TYPE string
      RETURNING VALUE(rv_body) TYPE string.

    "! JSON-RPC error envelope.
    CLASS-METHODS rpc_error
      IMPORTING iv_id_raw      TYPE string
                iv_code        TYPE i
                iv_message     TYPE string
                iv_data_json   TYPE string OPTIONAL
      RETURNING VALUE(rv_body) TYPE string.

    "! Merge additional members into a JSON object text. Both inputs must be
    "! serialized JSON objects; used to stamp the modern result envelope.
    CLASS-METHODS merge_object
      IMPORTING iv_base        TYPE string
                iv_extra       TYPE string
      RETURNING VALUE(rv_json) TYPE string.

    "! True when the text starts with `{` (after JSON whitespace).
    CLASS-METHODS is_json_object
      IMPORTING iv_json      TYPE string
      RETURNING VALUE(rv_yes) TYPE abap_bool.

    "! ABC_DEF -> abcDef (matches /UI2/CL_JSON pretty_mode-camel_case).
    CLASS-METHODS to_camel
      IMPORTING iv_name        TYPE string
      RETURNING VALUE(rv_name) TYPE string.

    "! Last-resort human readable label for a field without DDIC text.
    CLASS-METHODS humanize
      IMPORTING iv_name        TYPE string
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS class_constructor.

  PRIVATE SECTION.
    CLASS-DATA gv_ws  TYPE string.
    CLASS-DATA gv_cr  TYPE string.
    CLASS-DATA gv_lf  TYPE string.
    CLASS-DATA gv_tab TYPE string.

    CLASS-METHODS skip_ws
      IMPORTING iv_json TYPE string
                iv_len  TYPE i
      CHANGING  cv_pos TYPE i.

    CLASS-METHODS skip_value
      IMPORTING iv_json TYPE string
                iv_len  TYPE i
      CHANGING  cv_pos TYPE i.

    CLASS-METHODS clear_string
      IMPORTING iv_json TYPE string
                iv_len  TYPE i
      CHANGING  cv_pos TYPE i
                cv_value TYPE string.

    CLASS-METHODS id_token
      IMPORTING iv_raw          TYPE string
      RETURNING VALUE(rv_token) TYPE string.
ENDCLASS.


CLASS zcl_akit_mcp_json IMPLEMENTATION.

  METHOD class_constructor.
    DATA lv_crlf TYPE string.

    lv_crlf = cl_abap_char_utilities=>cr_lf.
    gv_cr   = lv_crlf+0(1).
    gv_lf   = lv_crlf+1(1).
    gv_tab  = cl_abap_char_utilities=>horizontal_tab.
    gv_ws   = ` ` && gv_tab && gv_cr && gv_lf.
  ENDMETHOD.


  METHOD to_json.
    TRY.
        rv_json = /ui2/cl_json=>serialize(
          data        = iv_data
          pretty_name = /ui2/cl_json=>pretty_mode-camel_case
          compress    = abap_true ).
      CATCH cx_root.
        rv_json = `null`.
    ENDTRY.
  ENDMETHOD.


  METHOD to_json_full.
    TRY.
        rv_json = /ui2/cl_json=>serialize(
          data        = iv_data
          pretty_name = /ui2/cl_json=>pretty_mode-camel_case
          compress    = abap_false ).
      CATCH cx_root.
        rv_json = `null`.
    ENDTRY.
  ENDMETHOD.


  METHOD extract_member.
    DATA lv_len    TYPE i.
    DATA lv_pos    TYPE i.
    DATA lv_start  TYPE i.
    DATA lv_member TYPE string.
    DATA lv_char   TYPE string.

    lv_len = strlen( iv_json ).
    IF lv_len = 0.
      RETURN.
    ENDIF.

    skip_ws( EXPORTING iv_json = iv_json iv_len = lv_len CHANGING cv_pos = lv_pos ).
    IF lv_pos >= lv_len OR iv_json+lv_pos(1) <> `{`.
      RETURN.
    ENDIF.
    lv_pos = lv_pos + 1.

    DO.
      skip_ws( EXPORTING iv_json = iv_json iv_len = lv_len CHANGING cv_pos = lv_pos ).
      IF lv_pos >= lv_len.
        RETURN.
      ENDIF.
      lv_char = iv_json+lv_pos(1).
      IF lv_char = `}`.
        RETURN.
      ENDIF.

      IF lv_char <> `"`.
        RETURN.
      ENDIF.
      clear_string( EXPORTING iv_json = iv_json iv_len = lv_len CHANGING cv_pos = lv_pos cv_value = lv_member ).

      skip_ws( EXPORTING iv_json = iv_json iv_len = lv_len CHANGING cv_pos = lv_pos ).
      IF lv_pos >= lv_len OR iv_json+lv_pos(1) <> `:`.
        RETURN.
      ENDIF.
      lv_pos = lv_pos + 1.
      skip_ws( EXPORTING iv_json = iv_json iv_len = lv_len CHANGING cv_pos = lv_pos ).

      lv_start = lv_pos.
      skip_value( EXPORTING iv_json = iv_json iv_len = lv_len CHANGING cv_pos = lv_pos ).

      IF lv_member = iv_name.
        DATA lv_take TYPE i.
        lv_take = lv_pos - lv_start.
        rv_raw  = iv_json+lv_start(lv_take).
        RETURN.
      ENDIF.

      skip_ws( EXPORTING iv_json = iv_json iv_len = lv_len CHANGING cv_pos = lv_pos ).
      IF lv_pos < lv_len AND iv_json+lv_pos(1) = `,`.
        lv_pos = lv_pos + 1.
      ELSE.
        RETURN.
      ENDIF.
    ENDDO.
  ENDMETHOD.


  METHOD skip_ws.
    DO.
      IF cv_pos >= iv_len.
        RETURN.
      ENDIF.
      IF iv_json+cv_pos(1) CA gv_ws.
        cv_pos = cv_pos + 1.
      ELSE.
        RETURN.
      ENDIF.
    ENDDO.
  ENDMETHOD.


  METHOD skip_value.
    DATA lv_char  TYPE string.
    DATA lv_depth TYPE i.
    DATA lv_dummy TYPE string.

    IF cv_pos >= iv_len.
      RETURN.
    ENDIF.

    lv_char = iv_json+cv_pos(1).
    IF lv_char = `"`.
      clear_string( EXPORTING iv_json = iv_json iv_len = iv_len CHANGING cv_pos = cv_pos cv_value = lv_dummy ).
      RETURN.
    ENDIF.

    IF lv_char = `{` OR lv_char = `[`.
      lv_depth = 0.
      DO.
        IF cv_pos >= iv_len.
          RETURN.
        ENDIF.
        lv_char = iv_json+cv_pos(1).
        IF lv_char = `"`.
          clear_string( EXPORTING iv_json = iv_json iv_len = iv_len CHANGING cv_pos = cv_pos cv_value = lv_dummy ).
          CONTINUE.
        ENDIF.
        IF lv_char = `{` OR lv_char = `[`.
          lv_depth = lv_depth + 1.
        ELSEIF lv_char = `}` OR lv_char = `]`.
          lv_depth = lv_depth - 1.
          IF lv_depth = 0.
            cv_pos = cv_pos + 1.
            RETURN.
          ENDIF.
        ENDIF.
        cv_pos = cv_pos + 1.
      ENDDO.
    ENDIF.

    " scalar (number / true / false / null)
    DO.
      IF cv_pos >= iv_len.
        RETURN.
      ENDIF.
      lv_char = iv_json+cv_pos(1).
      IF lv_char = `,` OR lv_char = `}` OR lv_char = `]` OR lv_char CA gv_ws.
        RETURN.
      ENDIF.
      cv_pos = cv_pos + 1.
    ENDDO.
  ENDMETHOD.


  METHOD clear_string.
    DATA lv_char TYPE string.

    " skip the opening quote
    cv_pos = cv_pos + 1.
    cv_value = ``.

    DO.
      IF cv_pos >= iv_len.
        RETURN.
      ENDIF.
      lv_char = iv_json+cv_pos(1).
      IF lv_char = `"`.
        cv_pos = cv_pos + 1.
        RETURN.
      ENDIF.
      IF lv_char = `\`.
        cv_pos = cv_pos + 1.
        IF cv_pos >= iv_len.
          RETURN.
        ENDIF.
        lv_char = iv_json+cv_pos(1).
        cv_pos = cv_pos + 1.
        CASE lv_char.
          WHEN `n`. cv_value = cv_value && gv_lf.
          WHEN `r`. cv_value = cv_value && gv_cr.
          WHEN `t`. cv_value = cv_value && gv_tab.
          WHEN OTHERS. cv_value = cv_value && lv_char.
        ENDCASE.
      ELSE.
        cv_value = cv_value && lv_char.
        cv_pos = cv_pos + 1.
      ENDIF.
    ENDDO.
  ENDMETHOD.


  METHOD parse_request.
    DATA ls_request TYPE zcl_akit_mcp_types=>ty_rpc_request.
    DATA lv_params  TYPE string.
    DATA lv_meta    TYPE string.
    DATA ls_meta    TYPE zcl_akit_mcp_types=>ty_meta.

    TRY.
        /ui2/cl_json=>deserialize(
          EXPORTING json        = iv_body
                    pretty_name = /ui2/cl_json=>pretty_mode-camel_case
          CHANGING  data        = ls_request ).
      CATCH cx_root.
        CLEAR ls_request.
    ENDTRY.

    " /UI2/CL_JSON cannot map the JSON member `_meta` to an ABAP component,
    " so it is extracted textually and deserialized separately.
    lv_params = extract_member( iv_json = iv_body iv_name = `params` ).
    IF lv_params IS NOT INITIAL.
      lv_meta = extract_member( iv_json = lv_params iv_name = `_meta` ).
      IF lv_meta IS NOT INITIAL.
        " Protocol metadata keys are namespaced (io.modelcontextprotocol/...).
        " Strip the prefix so the values map onto TY_META components.
        REPLACE ALL OCCURRENCES OF `"io.modelcontextprotocol/` IN lv_meta WITH `"`.
        TRY.
            /ui2/cl_json=>deserialize(
              EXPORTING json        = lv_meta
                        pretty_name = /ui2/cl_json=>pretty_mode-camel_case
              CHANGING  data        = ls_meta ).
            ls_request-params-meta = ls_meta.
          CATCH cx_root.
            CLEAR ls_meta.
        ENDTRY.
      ENDIF.
    ENDIF.

    rs_request = ls_request.
  ENDMETHOD.


  METHOD rpc_result.
    rv_body = `{"jsonrpc":"2.0","id":` && id_token( iv_id_raw )
           && `,"result":` && iv_result_json && `}`.
  ENDMETHOD.


  METHOD rpc_error.
    DATA ls_error TYPE zcl_akit_mcp_types=>ty_error_object.
    DATA lv_json  TYPE string.

    ls_error-code    = iv_code.
    ls_error-message = iv_message.
    lv_json = to_json( ls_error ).

    IF iv_data_json IS NOT INITIAL.
      lv_json = merge_object( iv_base  = lv_json
                              iv_extra = `"data":{` && iv_data_json && `}` ).
    ENDIF.

    rv_body = `{"jsonrpc":"2.0","id":` && id_token( iv_id_raw )
           && `,"error":` && lv_json && `}`.
  ENDMETHOD.


  METHOD merge_object.
    DATA lv_len   TYPE i.
    DATA lv_take  TYPE i.
    DATA lv_inner TYPE string.

    IF iv_base IS INITIAL OR iv_base = `{}`.
      rv_json = `{` && iv_extra && `}`.
      RETURN.
    ENDIF.

    lv_len = strlen( iv_base ).
    IF lv_len <= 2.
      rv_json = `{` && iv_extra && `}`.
    ELSE.
      lv_take  = lv_len - 2.
      lv_inner = iv_base+1(lv_take).
      rv_json  = `{` && lv_inner && `,` && iv_extra && `}`.
    ENDIF.
  ENDMETHOD.


  METHOD is_json_object.
    DATA lv_len   TYPE i.
    DATA lv_index TYPE i.
    DATA lv_char  TYPE string.

    lv_len = strlen( iv_json ).

    DO lv_len TIMES.
      lv_char = iv_json+lv_index(1).
      IF lv_char CA gv_ws.
        lv_index = lv_index + 1.
        CONTINUE.
      ENDIF.
      rv_yes = boolc( lv_char = '{' ).
      RETURN.
    ENDDO.
  ENDMETHOD.


  METHOD to_camel.
    DATA lv_name       TYPE string.
    DATA lv_char       TYPE string.
    DATA lv_out        TYPE string.
    DATA lv_index      TYPE i.
    DATA lv_upper_next TYPE abap_bool.

    lv_name = to_lower( iv_name ).

    DO strlen( lv_name ) TIMES.
      lv_char = lv_name+lv_index(1).
      IF lv_char = '_'.
        lv_upper_next = abap_true.
      ELSE.
        IF lv_upper_next = abap_true.
          lv_out        = lv_out && to_upper( lv_char ).
          lv_upper_next = abap_false.
        ELSE.
          lv_out = lv_out && lv_char.
        ENDIF.
      ENDIF.
      lv_index = lv_index + 1.
    ENDDO.

    rv_name = lv_out.
  ENDMETHOD.


  METHOD humanize.
    DATA lv_text TYPE string.

    lv_text = to_lower( iv_name ).
    REPLACE ALL OCCURRENCES OF '_' IN lv_text WITH space.
    rv_text = condense( lv_text ).
  ENDMETHOD.


  METHOD id_token.
    DATA lv_first TYPE string.

    IF iv_raw IS INITIAL.
      rv_token = `null`.
      RETURN.
    ENDIF.

    IF iv_raw = `null`.
      rv_token = `null`.
      RETURN.
    ENDIF.

    lv_first = iv_raw(1).
    IF lv_first = `"` OR lv_first = `-` OR ( lv_first CO `0123456789` ).
      rv_token = iv_raw.
    ELSE.
      " JSON-RPC ids are string / number / null only: never echo objects.
      rv_token = `null`.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
