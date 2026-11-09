FUNCTION zlily_diag_query.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     REFERENCE(IV_TABLE) TYPE  TABNAME
*"     REFERENCE(IV_MAX_ROWS) TYPE  I DEFAULT 1000
*"  EXPORTING
*"     REFERENCE(EV_ERROR) TYPE  STRING
*"     REFERENCE(EV_ROW_COUNT) TYPE  I
*"  TABLES
*"     IT_WHERE STRUCTURE  RFC_DB_OPT
*"     ET_DATA STRUCTURE  ZDIAG_CELL
*"----------------------------------------------------------------------
* ZLILY_DIAG_QUERY - read-only diagnostic query (replaces RFC_READ_TABLE).
*
* Fixes vs RFC_READ_TABLE:
*   (1) NO 512-char WA truncation  - each cell value is emitted as STRING.
*   (2) Full WHERE incl. parentheses and OR - dynamic WHERE (lt_cond).
*   (3) Returns ALL columns of iv_table, correctly typed per cell.
*
* Result is "long format": one ET_DATA row per (data row x column):
*   ROW_INDEX | FIELDNAME | VALUE(STRING)
* The caller (MCP sap_query) pivots it back into row objects by ROW_INDEX.
*
* NOT in this version (later): JOIN, explicit field list (IT_FIELDS),
* ROWSKIP offset paging (UP TO caps rows; caller narrows WHERE if more).
*
* POLICY: STRICTLY READ-ONLY (SELECT only). ECC syntax (no 7.40+).

  DATA: lr_table TYPE REF TO data,
        lo_struc TYPE REF TO cl_abap_structdescr,
        lt_comp  TYPE abap_compdescr_tab,
        ls_comp  LIKE LINE OF lt_comp,
        ls_opt   TYPE rfc_db_opt,
        lt_cond  TYPE TABLE OF string,
        lv_row   TYPE i,
        lv_val   TYPE string,
        ls_cell  TYPE zdiag_cell,
        lo_x     TYPE REF TO cx_root.

  FIELD-SYMBOLS: <ft> TYPE STANDARD TABLE,
                 <fs> TYPE ANY,
                 <fv> TYPE ANY.

* --- describe the table line type (gives the column list) ---
  TRY.
      lo_struc ?= cl_abap_typedescr=>describe_by_name( iv_table ).
    CATCH cx_root INTO lo_x.
      ev_error = lo_x->get_text( ).
      RETURN.
  ENDTRY.
  lt_comp = lo_struc->components.

* --- dynamic SELECT into a dynamic internal table ---
  CREATE DATA lr_table TYPE TABLE OF (iv_table).
  ASSIGN lr_table->* TO <ft>.

  LOOP AT it_where INTO ls_opt.
    APPEND ls_opt-text TO lt_cond.
  ENDLOOP.

  TRY.
      IF lt_cond IS INITIAL.
        SELECT *
          FROM (iv_table)
          INTO TABLE <ft>
          UP TO iv_max_rows ROWS.
      ELSE.
        SELECT *
          FROM (iv_table)
          INTO TABLE <ft>
          WHERE (lt_cond)
          UP TO iv_max_rows ROWS.
      ENDIF.
    CATCH cx_root INTO lo_x.
      ev_error = lo_x->get_text( ).
      RETURN.
  ENDTRY.

  DESCRIBE TABLE <ft> LINES ev_row_count.

* --- emit long-format cells: one ET_DATA row per (data row x column) ---
  LOOP AT <ft> ASSIGNING <fs>.
    lv_row = sy-tabix.
    LOOP AT lt_comp INTO ls_comp.
      ASSIGN COMPONENT ls_comp-name OF STRUCTURE <fs> TO <fv>.
      IF sy-subrc = 0.
        lv_val = <fv>.
        CLEAR ls_cell.
        ls_cell-row_index = lv_row.
        ls_cell-fieldname = ls_comp-name.
        ls_cell-value     = lv_val.
        APPEND ls_cell TO et_data.
      ENDIF.
    ENDLOOP.
  ENDLOOP.

ENDFUNCTION.
