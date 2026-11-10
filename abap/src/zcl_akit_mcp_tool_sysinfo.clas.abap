CLASS zcl_akit_mcp_tool_sysinfo DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    CLASS-METHODS get_meta
      RETURNING VALUE(rs_meta) TYPE zcl_akit_mcp_types=>ty_tool_meta.

    CLASS-METHODS execute
      RETURNING VALUE(rv_result) TYPE string.

  PRIVATE SECTION.
    TYPES:
      BEGIN OF ty_result,
        system_id          TYPE string,
        client             TYPE string,
        user               TYPE string,
        abap_release       TYPE string,
        database_system    TYPE string,
        application_server TYPE string,
        language           TYPE string,
        date               TYPE string,
        time               TYPE string,
        server_name        TYPE string,
        server_version     TYPE string,
      END OF ty_result.
ENDCLASS.


CLASS zcl_akit_mcp_tool_sysinfo IMPLEMENTATION.

  METHOD get_meta.
    rs_meta = VALUE #(
      name        = 'sap_info'
      title       = 'SAP 系统信息'
      description = '返回当前 SAP 系统、客户端、登录用户、ABAP 版本、数据库、应用服务器、语言与日期时间。只读，无参数。'
      args_struct = ``
      required    = VALUE #( )
      write       = abap_false
      raw_args    = abap_false
      raw_schema  = `` ).
  ENDMETHOD.


  METHOD execute.
    DATA ls_result TYPE ty_result.

    ls_result-system_id          = sy-sysid.
    ls_result-client             = sy-mandt.
    ls_result-user               = sy-uname.
    ls_result-abap_release       = sy-saprl.
    ls_result-database_system    = sy-dbsys.
    ls_result-application_server = sy-host.
    ls_result-language           = sy-langu.
    ls_result-date               = sy-datum.
    ls_result-time               = sy-uzeit.
    ls_result-server_name        = zcl_akit_mcp_types=>gc_server_name.
    ls_result-server_version     = zcl_akit_mcp_types=>gc_version.

    rv_result = zcl_akit_mcp_json=>to_json_full( ls_result ).
  ENDMETHOD.

ENDCLASS.
