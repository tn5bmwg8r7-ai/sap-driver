FUNCTION ZLILY_DIAG_GEN_EXEC.
*"----------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_AREA) TYPE  CHAR30
*"     VALUE(IV_PROGID) TYPE  CHAR30
*"     VALUE(IV_DATAID) TYPE  CHAR30
*"  EXPORTING
*"     VALUE(EV_RESULT) TYPE  STRING
*"     VALUE(EV_ERROR) TYPE  STRING
*"  TABLES
*"      IT_SRC STRUCTURE  ABAPSOURCE
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
DATA: lv_prog   TYPE string,
      lv_msg    TYPE string,
      lv_result TYPE string,
      lv_j      TYPE string.

GENERATE SUBROUTINE POOL it_src NAME lv_prog
  MESSAGE lv_msg.
IF sy-subrc <> 0.
  CONCATENATE 'gen err:' lv_msg INTO ev_error
    SEPARATED BY space.
  RETURN.
ENDIF.

PERFORM r IN PROGRAM (lv_prog)
  USING iv_area iv_progid iv_dataid.

IMPORT lv_j TO lv_result FROM MEMORY ID 'ZLILY_VR'.
IF sy-subrc = 0.
  ev_result = lv_result.
ELSE.
  ev_error = 'no data in memory'.
ENDIF.
FREE MEMORY ID 'ZLILY_VR'.
ENDFUNCTION.
