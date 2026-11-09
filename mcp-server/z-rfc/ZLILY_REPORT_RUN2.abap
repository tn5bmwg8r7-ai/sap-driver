FUNCTION ZLILY_REPORT_RUN2.
*"  IMPORTING
*"     VALUE(IV_REPORT) TYPE CHAR40
*"     VALUE(IV_VARIANT) TYPE VARIANT OPTIONAL
*"     VALUE(IV_ENFORCE) TYPE CHAR1 DEFAULT SPACE
*"     VALUE(IV_FORCE) TYPE CHAR1 DEFAULT SPACE
*"     VALUE(IV_MAX_WAIT) TYPE INT4 DEFAULT 75
*"  EXPORTING
*"     VALUE(EV_STATUS) TYPE CHAR10
*"     VALUE(EV_JOBNAME) TYPE TBTCO-JOBNAME
*"     VALUE(EV_JOBCOUNT) TYPE TBTCO-JOBCOUNT
*"     VALUE(EV_SUBRC) TYPE SYSUBRC
*"     VALUE(EV_MESSAGE) TYPE BAPI_MSG
*"     VALUE(EV_LINES) TYPE INT4
*"     VALUE(EV_MS) TYPE INT4
*"  TABLES
*"      IT_SELTAB STRUCTURE RSPARAMS
*"      ET_LIST STRUCTURE SOLI
*"      ET_RISK STRUCTURE BAPIRET2
*"----------------------------------------------------------------------
*-- v12(2026-09-15):标准+自定义报表后台真跑,spool 取回列表。
*-- 治理:①ABAP 白名单闸;②标准报表粗扫风险,IV_ENFORCE='X'(PRD)
*-- 且风险非 CLEAN 且 IV_FORCE<>'X' → REFUSED;③后台作业执行,
*-- IV_MAX_WAIT(5~80s)内未完 → RUNNING+作业号,由调用方 poll 接力。
*-- 打印参数:LOCL→LP01→LP02→用户默认 逐级回退(DVP 无 LOCL 实爆)。
*-- TBTCO 终态:本机实测定案 F=完成 A=取消(无 S 态,09-15 实测)。
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

DATA: lv_prog   TYPE progname,
      lv_subc   TYPE reposrc-subc,
      lv_lvl    TYPE char6,
      lv_std    TYPE c,
      lv_ssubrc TYPE sysubrc,
      lv_smsg   TYPE bapi_msg,
      lv_jobname TYPE tbtcjob-jobname,
      lv_jcount  TYPE tbtcjob-jobcount,
      ls_pri    TYPE pri_params,
      lv_valid  TYPE c,
      lv_stat   TYPE tbtco-status,
      lv_maxw   TYPE i,
      lv_waited TYPE i,
      lv_t1     TYPE i,
      lv_t2     TYPE i,
      lv_spl    TYPE sysubrc,
      lv_wc(3)  TYPE c.
CLEAR: ev_status, ev_jobname, ev_jobcount, ev_subrc,
       ev_message, ev_lines, ev_ms, lv_std.
REFRESH: et_list, et_risk.
CONDENSE iv_report.
TRANSLATE iv_report TO UPPER CASE.
SELECT SINGLE progname subc FROM reposrc
  INTO (lv_prog, lv_subc)
  WHERE progname = iv_report AND r3state = 'A'.
IF sy-subrc <> 0.
  ev_status = 'ERROR'.
  ev_subrc = 8.
  CONCATENATE 'ERR: no report:' iv_report
    INTO ev_message SEPARATED BY space.
  RETURN.
ENDIF.
IF lv_subc <> '1'.
  ev_status = 'ERROR'.
  ev_subrc = 8.
  ev_message = 'ERR: not type-1 executable'.
  RETURN.
ENDIF.
*-- 副作用粗扫(同函数组 ZLILY_REPORT_SCAN,风险清单直接带出)
CALL FUNCTION 'ZLILY_REPORT_SCAN'
  EXPORTING iv_report = iv_report
  IMPORTING ev_subrc = lv_ssubrc
            ev_risk_level = lv_lvl
            ev_message = lv_smsg
  TABLES et_risk = et_risk.
IF lv_ssubrc <> 0.
  ev_status = 'ERROR'.
  ev_subrc = lv_ssubrc.
  ev_message = lv_smsg.
  RETURN.
ENDIF.
*-- 治理闸:标准报表 + PRD(ENFORCE) + 有风险 + 未确认 → 拒
IF iv_report(1) NA 'ZY'.
  lv_std = 'X'.
ENDIF.
IF lv_std = 'X' AND iv_enforce = 'X'
    AND lv_lvl <> 'CLEAN' AND iv_force <> 'X'.
  ev_status = 'REFUSED'.
  ev_subrc = 8.
  CONCATENATE 'ERR: RISK_BLOCKED level' lv_lvl
    INTO ev_message SEPARATED BY space.
  RETURN.
ENDIF.
*-- 后台作业化:作业名 ZL_报表前9位_日期_时间(≤32 字符)
CONCATENATE 'ZL_' iv_report(9) '_' sy-datum '_' sy-uzeit
  INTO lv_jobname.
CONDENSE lv_jobname NO-GAPS.
CALL FUNCTION 'JOB_OPEN'
  EXPORTING jobname = lv_jobname
  IMPORTING jobcount = lv_jcount
  EXCEPTIONS cant_create_job = 1
             invalid_job_data = 2
             jobname_missing = 3
             OTHERS = 4.
IF sy-subrc <> 0.
  ev_status = 'ERROR'.
  ev_subrc = 8.
  ev_message = 'ERR: job open failed'.
  RETURN.
ENDIF.
*-- 打印参数:LOCL→LP01→LP02→用户默认,逐级回退
CLEAR lv_valid.
CALL FUNCTION 'GET_PRINT_PARAMETERS'
  EXPORTING destination = 'LOCL'
            no_dialog = 'X'
  IMPORTING out_parameters = ls_pri
            valid = lv_valid
  EXCEPTIONS OTHERS = 4.
IF lv_valid <> 'X'.
  CLEAR lv_valid.
  CALL FUNCTION 'GET_PRINT_PARAMETERS'
    EXPORTING destination = 'LP01'
              no_dialog = 'X'
    IMPORTING out_parameters = ls_pri
              valid = lv_valid
    EXCEPTIONS OTHERS = 4.
ENDIF.
IF lv_valid <> 'X'.
  CLEAR lv_valid.
  CALL FUNCTION 'GET_PRINT_PARAMETERS'
    EXPORTING destination = 'LP02'
              no_dialog = 'X'
    IMPORTING out_parameters = ls_pri
              valid = lv_valid
    EXCEPTIONS OTHERS = 4.
ENDIF.
IF lv_valid <> 'X'.
  CLEAR lv_valid.
  CALL FUNCTION 'GET_PRINT_PARAMETERS'
    EXPORTING no_dialog = 'X'
    IMPORTING out_parameters = ls_pri
              valid = lv_valid
    EXCEPTIONS OTHERS = 4.
ENDIF.
IF lv_valid <> 'X'.
  ev_status = 'ERROR'.
  ev_subrc = 8.
  ev_message = 'ERR: print parameters'.
  RETURN.
ENDIF.
IF iv_variant IS NOT INITIAL.
  SUBMIT (iv_report) USING SELECTION-SET iv_variant
    WITH SELECTION-TABLE it_seltab
    VIA JOB lv_jobname NUMBER lv_jcount
    TO SAP-SPOOL SPOOL PARAMETERS ls_pri
    WITHOUT SPOOL DYNPRO AND RETURN.
ELSE.
  SUBMIT (iv_report) WITH SELECTION-TABLE it_seltab
    VIA JOB lv_jobname NUMBER lv_jcount
    TO SAP-SPOOL SPOOL PARAMETERS ls_pri
    WITHOUT SPOOL DYNPRO AND RETURN.
ENDIF.
CALL FUNCTION 'JOB_CLOSE'
  EXPORTING jobcount = lv_jcount
            jobname = lv_jobname
            strtimmed = 'X'
  EXCEPTIONS cant_start_immediately = 1
             invalid_startdate = 2
             jobname_missing = 3
             job_close_failed = 4
             job_nosteps = 5
             job_notex = 6
             lock_failed = 7
             OTHERS = 8.
IF sy-subrc <> 0.
  ev_status = 'ERROR'.
  ev_subrc = 8.
  ev_message = 'ERR: job close failed'.
  RETURN.
ENDIF.
ev_jobname = lv_jobname.
ev_jobcount = lv_jcount.
*-- 轮询 TBTCO:主键单读,有界 ≤40 次(2s 间隔),SQL 五关合规。
*-- 终态 F=完成 A=取消(本系统实测定案,无 S 态)
lv_maxw = iv_max_wait.
IF lv_maxw < 5.
  lv_maxw = 5.
ENDIF.
IF lv_maxw > 80.
  lv_maxw = 80.
ENDIF.
GET RUN TIME FIELD lv_t1.
lv_waited = 0.
DO.
  SELECT SINGLE status FROM tbtco INTO lv_stat
    WHERE jobname = lv_jobname AND jobcount = lv_jcount.
  IF sy-subrc = 0 AND ( lv_stat = 'F' OR lv_stat = 'A' ).
    EXIT.
  ENDIF.
  IF lv_waited >= lv_maxw.
    EXIT.
  ENDIF.
  WAIT UP TO 2 SECONDS.
  ADD 2 TO lv_waited.
ENDDO.
GET RUN TIME FIELD lv_t2.
ev_ms = ( lv_t2 - lv_t1 ) / 1000.
IF lv_stat <> 'F' AND lv_stat <> 'A'.
  ev_status = 'RUNNING'.
  ev_message = 'NOTE: still running after'.
  WRITE lv_maxw TO lv_wc.
  CONCATENATE ev_message lv_wc 's'
    INTO ev_message SEPARATED BY space.
  RETURN.
ENDIF.
*-- 完成/取消:取 spool 文本(取消也取,可能有部分输出)
IF lv_stat = 'A'.
  ev_status = 'CANCELLED'.
  ev_subrc = 8.
  ev_message = 'NOTE: job cancelled (A)'.
ELSE.
  ev_status = 'DONE'.
ENDIF.
CALL FUNCTION 'ZLILY_REPORT_SPOOL'
  EXPORTING iv_jobname = lv_jobname
            iv_jobcount = lv_jcount
  IMPORTING ev_subrc = lv_spl
            ev_message = lv_smsg
            ev_lines = ev_lines
  TABLES et_list = et_list.
IF lv_spl <> 0 AND ev_message IS INITIAL.
  ev_subrc = lv_spl.
  ev_message = lv_smsg.
ENDIF.
IF ev_lines = 0 AND ev_message IS INITIAL.
  ev_message = 'NOTE: no list output (grid ALV?)'.
ENDIF.
ENDFUNCTION.
