FUNCTION ZLILY_REPORT_SPOOL.
*"  IMPORTING
*"     VALUE(IV_JOBNAME) TYPE TBTCO-JOBNAME
*"     VALUE(IV_JOBCOUNT) TYPE TBTCO-JOBCOUNT
*"  EXPORTING
*"     VALUE(EV_SUBRC) TYPE SYSUBRC
*"     VALUE(EV_MESSAGE) TYPE BAPI_MSG
*"     VALUE(EV_LINES) TYPE INT4
*"  TABLES
*"      ET_LIST STRUCTURE SOLI
*"----------------------------------------------------------------------
*-- v12(2026-09-15):按作业取 spool 列表文本。
*-- TBTCP-LISTIDENT 定位 spool 号,读文本走等价链(09-09 定案):
*--   SUBMIT rspolist → LIST_FROM_MEMORY → LIST_TO_ASCI
*-- (RSPO_RETURN_ABAP_SPOOLJOB 的 TABLES BUFFER 是裸泛型,传表必撞
*--  CALL_FUNCTION_CONFLICT_TYPE,dump 实证,弃用。)
DATA: lt_allow LIKE TABLE OF sy-uname,
      lv_wu    LIKE sy-uname,
      lv_wok   TYPE c,
      lv_wconf TYPE zmmd_value.
SELECT SINGLE value FROM zmmt_config INTO lv_wconf
  WHERE key1 = 'ZLILY_WHITELIST'.
IF sy-subrc = 0 AND lv_wconf IS NOT INITIAL.
  SPLIT lv_wconf AT ',' INTO TABLE lt_allow.
ELSE.
  APPEND '<你的SAP用户名>' TO lt_allow.  " 开源版占位:改为部署者的 SAP 用户名(白名单 fallback,生产建议删除此行走配置表)
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
  ev_subrc = 4.
  ev_message = 'ERR: caller not in whitelist'.
  RETURN.
ENDIF.

DATA: lv_spool(10) TYPE n,
      lv_rqi       TYPE i.
DATA: lt_mem LIKE abaplist OCCURS 10.
DATA: lt_asc LIKE soli OCCURS 10 WITH HEADER LINE.
DATA: lv_sc(10) TYPE c.
CLEAR: ev_subrc, ev_message, ev_lines.
REFRESH et_list.
SELECT SINGLE listident FROM tbtcp INTO lv_spool
  WHERE jobname = iv_jobname AND jobcount = iv_jobcount
    AND listident <> '0000000000'.
IF sy-subrc <> 0 OR lv_spool IS INITIAL.
  ev_subrc = 8.
  ev_message = 'ERR: no spool output for this job'.
  RETURN.
ENDIF.
lv_rqi = lv_spool.
SUBMIT rspolist WITH rqident = lv_rqi
  EXPORTING LIST TO MEMORY AND RETURN.
CALL FUNCTION 'LIST_FROM_MEMORY'
  TABLES listobject = lt_mem
  EXCEPTIONS not_found = 1
             OTHERS = 2.
IF sy-subrc <> 0.
  ev_subrc = 8.
  ev_message = 'ERR: spool list not found'.
  RETURN.
ENDIF.
CALL FUNCTION 'LIST_TO_ASCI'
  TABLES listobject = lt_mem
         listasci = lt_asc
  EXCEPTIONS empty_list = 1
             OTHERS = 2.
IF sy-subrc <> 0.
  ev_subrc = 8.
  ev_message = 'ERR: list to asci failed'.
  RETURN.
ENDIF.
CALL FUNCTION 'LIST_FREE_MEMORY'
  TABLES listobject = lt_mem.
LOOP AT lt_asc.
  APPEND lt_asc TO et_list.
ENDLOOP.
DESCRIBE TABLE et_list LINES ev_lines.
ENDFUNCTION.
