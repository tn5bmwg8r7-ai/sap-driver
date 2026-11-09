
FUNCTION ZLILY_DIAG_Q3.
*"--------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_TABLE) TYPE  TABNAME
*"     VALUE(IV_MAX_ROWS) TYPE  I DEFAULT 1000
*"  EXPORTING
*"     VALUE(EV_RESULT) TYPE  STRING
*"     VALUE(EV_ERROR) TYPE  STRING
*"     VALUE(EV_ROW_COUNT) TYPE  I
*"  TABLES
*"      IT_WHERE STRUCTURE  RFC_DB_OPT
*"--------------------------------------------------------------------
*-- 2026-09-15 白名单闸:ZMMT_CONFIG/KEY1=ZLILY_WHITELIST,逗号分隔 --*
DATA: lt_allow LIKE TABLE OF sy-uname,
      lv_u     LIKE sy-uname,
      lv_ok    TYPE c,
      lv_conf  TYPE zmmd_value.
SELECT SINGLE value FROM zmmt_config INTO lv_conf
  WHERE key1 = 'ZLILY_WHITELIST'.
IF sy-subrc = 0 AND lv_conf IS NOT INITIAL.
  SPLIT lv_conf AT ',' INTO TABLE lt_allow.
ELSE.
  APPEND '<你的SAP用户名>' TO lt_allow.  " 开源版占位:改为部署者的 SAP 用户名(白名单 fallback,生产建议删除此行走配置表)
ENDIF.
LOOP AT lt_allow INTO lv_u.
  CONDENSE lv_u.
  TRANSLATE lv_u TO UPPER CASE.
  IF lv_u = sy-uname.
    lv_ok = 'X'.
    EXIT.
  ENDIF.
ENDLOOP.
IF lv_ok IS INITIAL.
  ev_error = 'ERR: caller not in whitelist'.
  RETURN.
ENDIF.
*-- 白名单闸结束 --*
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

CALL FUNCTION 'DDIF_FIELDINFO_GET'
  EXPORTING TABNAME = iv_table
  TABLES    DFIES_TAB = lt_fields
  EXCEPTIONS OTHERS = 1.

CREATE DATA lr_table TYPE TABLE OF (iv_table).
ASSIGN lr_table->* TO <ft>.

LOOP AT it_where INTO ls_opt.
  APPEND ls_opt-text TO lt_cond.
ENDLOOP.

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

IF ev_row_count > iv_max_rows.
  DELETE <ft> FROM iv_max_rows + 1.
ENDIF.

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




