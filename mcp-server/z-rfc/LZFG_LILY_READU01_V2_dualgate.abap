
FUNCTION zlily_diag_unpack.
*"--------------------------------------------------------------------
*"*"局部接口:
*"  IMPORTING
*"     VALUE(IV_INCL) TYPE  PROGNAME
*"  EXPORTING
*"     VALUE(EV_RESULT) TYPE  STRING
*"     VALUE(EV_ERROR) TYPE  STRING
*"--------------------------------------------------------------------
*-- 2026-10-09 双闸:1表权限S_TABU_DIS 2白名单保底 --*
DATA: lv_cclass TYPE tddat-cclass,
      lt_allow  LIKE TABLE OF sy-uname,
      lv_u      LIKE sy-uname,
      lv_ok     TYPE c,
      lv_conf   TYPE zmmd_value.
*-- 1) 表权限闸:源码表REPOSRC权限组,与SE16同权 --*
SELECT SINGLE cclass FROM tddat INTO lv_cclass
  WHERE tabname = 'REPOSRC'.
IF sy-subrc <> 0.
  lv_cclass = '&NA&'.
ENDIF.
AUTHORITY-CHECK OBJECT 'S_TABU_DIS'
  ID 'DIC_BERCLS' FIELD lv_cclass
  ID 'ACTVT' FIELD '03'.
IF sy-subrc = 0.
  lv_ok = 'X'.
ELSE.
*-- 2) 白名单保底:ZMMT_CONFIG KEY1=ZLILY_WHITELIST --*
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
ENDIF.
IF lv_ok IS INITIAL.
  CONCATENATE 'ERR: no S_TABU_DIS(' lv_cclass
              ') authority for source read'
              'and not in whitelist'
    INTO ev_error SEPARATED BY space.
  RETURN.
ENDIF.
DATA: lt_src TYPE TABLE OF abaptxt255,
      ls_src TYPE abaptxt255,
      lv_nl  TYPE string.

lv_nl = cl_abap_char_utilities=>newline.

READ REPORT iv_incl INTO lt_src.
IF sy-subrc <> 0.
  ev_error = 'READ REPORT failed'.
  RETURN.
ENDIF.
LOOP AT lt_src INTO ls_src.
  CONCATENATE ev_result ls_src INTO ev_result SEPARATED BY lv_nl.
ENDLOOP.

ENDFUNCTION.
