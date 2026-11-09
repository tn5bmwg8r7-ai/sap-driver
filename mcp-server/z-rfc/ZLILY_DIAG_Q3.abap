FUNCTION zlily_diag_q3.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     REFERENCE(IV_TABLE) TYPE  TABNAME
*"     REFERENCE(IV_MAX_ROWS) TYPE  I DEFAULT 1000
*"  EXPORTING
*"     REFERENCE(EV_RESULT) TYPE  STRING
*"     REFERENCE(EV_ERROR) TYPE  STRING
*"     REFERENCE(EV_ROW_COUNT) TYPE  I
*"  TABLES
*"     IT_WHERE STRUCTURE  RFC_DB_OPT
*"----------------------------------------------------------------------
* ZLILY_DIAG_Q3 - read-only diagnostic query, JSON output (Layer 2 RFC).
* Replaces RFC_READ_TABLE: NO 512-char truncation, full WHERE (parens/OR),
* all columns returned as JSON array in EV_RESULT.
*
* Old-ECC compatible (system does NOT support new syntax):
*   - NO "UP TO n ROWS" -> SELECT all + DELETE FROM maxRows+1
*   - NO inline declarations / constructor expressions / table expressions
*   - field names via DDIF_FIELDINFO_GET (NOT RTTS abap_compdescr_tab)
*
* Why JSON STRING (not a typed table): stateless RFC does NOT persist DDIC
* creates (DDIF_TABL_PUT rolls back), so we avoid a ZDIAG_CELL structure
* entirely and serialize to STRING.
*
* POLICY: STRICTLY READ-ONLY (SELECT only).

  DATA: lr_table TYPE REF TO data,
        lt_fields TYPE TABLE OF dfies,
        ls_field  TYPE dfies,
        ls_opt    TYPE rfc_db_opt,
        lt_cond   TYPE TABLE OF string,
        lv_val    TYPE string,
        lo_x      TYPE REF TO cx_root.

  FIELD-SYMBOLS: <ft> TYPE STANDARD TABLE,
                 <fs> TYPE ANY,
                 <fv> TYPE ANY.

* --- field list via DDIF (standard RFC FM, no RTTS) ---
  CALL FUNCTION 'DDIF_FIELDINFO_GET'
    EXPORTING TABNAME = iv_table
    TABLES    DFIES_TAB = lt_fields
    EXCEPTIONS OTHERS = 1.

  CREATE DATA lr_table TYPE TABLE OF (iv_table).
  ASSIGN lr_table->* TO <ft>.

  LOOP AT it_where INTO ls_opt.
    APPEND ls_opt-text TO lt_cond.
  ENDLOOP.

* --- dynamic SELECT (no UP TO — old ECC) ---
  TRY.
      IF lt_cond IS INITIAL.
        SELECT * FROM (iv_table) INTO TABLE <ft>.
      ELSE.
        SELECT * FROM (iv_table) INTO TABLE <ft>
          WHERE (lt_cond).
      ENDIF.
    CATCH cx_root INTO lo_x.
      ev_error = lo_x->get_text( ).
      RETURN.
  ENDTRY.

  DESCRIBE TABLE <ft> LINES ev_row_count.

* --- cap rows (replacement for UP TO n ROWS) ---
  IF ev_row_count > iv_max_rows.
    DELETE <ft> FROM iv_max_rows + 1.
  ENDIF.

* --- emit JSON array [{...},...] ---
  ev_result = '['.
  LOOP AT <ft> ASSIGNING <fs>.
    IF sy-tabix > 1.
      CONCATENATE ev_result ',' INTO ev_result.
    ENDIF.
    CONCATENATE ev_result '{' INTO ev_result.
    LOOP AT lt_fields INTO ls_field.
      ASSIGN COMPONENT ls_field-fieldname OF STRUCTURE <fs> TO <fv>.
      IF sy-subrc = 0.
        IF sy-tabix > 1.
          CONCATENATE ev_result ',' INTO ev_result.
        ENDIF.
        lv_val = <fv>.
        CONCATENATE ev_result '"' ls_field-fieldname '":"' lv_val '"'
                    INTO ev_result.
      ENDIF.
    ENDLOOP.
    CONCATENATE ev_result '}' INTO ev_result.
  ENDLOOP.
  CONCATENATE ev_result ']' INTO ev_result.

ENDFUNCTION.
