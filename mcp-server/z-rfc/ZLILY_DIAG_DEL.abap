FUNCTION ZLILY_DIAG_DEL.
*"----------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_FUNCNAME) TYPE  RS38L_FNAM
*"  EXPORTING
*"     VALUE(EV_ERROR) TYPE  STRING
*"----------------------------------------------------------------------
*-- 2026-09-15 白名单闸:ZMMT_CONFIG/KEY1=ZLILY_WHITELIST,逗号分隔 --*
DATA: lt_allow LIKE TABLE OF sy-uname,
      lv_wu    LIKE sy-uname,
      lv_wok   TYPE c,
      lv_wconf TYPE zmmd_value.
SELECT SINGLE value FROM zmmt_config INTO lv_wconf
  WHERE key1 = 'ZLILY_WHITELIST'.
IF sy-subrc = 0 AND lv_wconf IS NOT INITIAL.
  SPLIT lv_wconf AT ',' INTO TABLE lt_allow.
ELSE.
  APPEND '<你的SAP用户名>' TO lt_allow.
ENDIF.
LOOP AT lt_allow INTO lv_wu.
  CONDENSE lv_wu.
  TRANSLATE lv_wu TO UPPER CASE.
  IF lv_wu = sy-uname.
    lv_wok = 'X'.
    EXIT.
  ENDIF.
ENDLOOP.
IF lv_wok IS INITIAL.
  ev_error = 'ERR: caller not in whitelist'.
  RETURN.
ENDIF.
*-- 白名单闸结束 --*
DATA: lo_x TYPE REF TO cx_root.

IF iv_funcname IS INITIAL.
  ev_error = 'need funcname'.
  RETURN.
ENDIF.
IF iv_funcname(1) NA 'ZY'.
  ev_error = 'func not Z/Y'.
  RETURN.
ENDIF.

TRY.
    CALL FUNCTION 'FUNCTION_DELETE'
      EXPORTING
        funcname                 = iv_funcname
        suppress_success_message = 'X'
        suppress_lock            = 'X'
      EXCEPTIONS
        others                   = 1.
    IF sy-subrc <> 0.
      ev_error = 'FUNCTION_DELETE rc non-zero'.
    ENDIF.
  CATCH cx_root INTO lo_x.
    ev_error = lo_x->get_text( ).
ENDTRY.
ENDFUNCTION.
