FUNCTION ZLILY_DIAG_SRC_PUT8.
*"----------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_FUNCNAME) TYPE  RS38L_FNAM
*"     VALUE(IV_PROG) TYPE  PROGNAME
*"     VALUE(IV_DEVCLASS) TYPE  DEVCLASS
*"     VALUE(IV_TRKORR) TYPE  TRKORR
*"  EXPORTING
*"     VALUE(EV_TARGET) TYPE  PROGNAME
*"     VALUE(EV_ERROR) TYPE  STRING
*"  TABLES
*"      IT_SOURCE STRUCTURE  ABAPSOURCE
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
DATA: lv_pname TYPE pname,
      lv_inc   TYPE includenr,
      lv_pool  TYPE string,
      lt_src   TYPE TABLE OF abapsource,
      lo_x     TYPE REF TO cx_root.

lt_src[] = it_source[].

IF iv_funcname IS NOT INITIAL.
  IF iv_funcname(1) NA 'ZY'.
    ev_error = 'func not Z/Y'.
    RETURN.
  ENDIF.
  SELECT SINGLE pname include INTO (lv_pname, lv_inc) FROM tfdir
    WHERE funcname = iv_funcname.
  IF sy-subrc <> 0.
    ev_error = 'func not in tfdir'.
    RETURN.
  ENDIF.
  lv_pool = lv_pname+4.
  CONDENSE lv_pool.
  CONCATENATE 'L' lv_pool 'U' lv_inc INTO ev_target.
ELSEIF iv_prog IS NOT INITIAL.
  IF iv_prog(1) NA 'ZY'.
    ev_error = 'prog not Z/Y'.
    RETURN.
  ENDIF.
  ev_target = iv_prog.
ELSE.
  ev_error = 'need funcname or prog'.
  RETURN.
ENDIF.

TRY.
    INSERT REPORT ev_target FROM lt_src.
    IF sy-subrc <> 0.
      ev_error = 'INSERT REPORT failed'.
    ENDIF.
  CATCH cx_root INTO lo_x.
    ev_error = lo_x->get_text( ).
ENDTRY.
ENDFUNCTION.
