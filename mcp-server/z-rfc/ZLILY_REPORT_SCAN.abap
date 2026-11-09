FUNCTION ZLILY_REPORT_SCAN.
*"  IMPORTING
*"     VALUE(IV_REPORT) TYPE CHAR40
*"  EXPORTING
*"     VALUE(EV_SUBRC) TYPE SYSUBRC
*"     VALUE(EV_RISK_LEVEL) TYPE CHAR6
*"     VALUE(EV_MESSAGE) TYPE BAPI_MSG
*"  TABLES
*"      ET_RISK STRUCTURE BAPIRET2
*"----------------------------------------------------------------------
*-- v12(2026-09-15)定点排查:报表源码副作用粗扫,纯只读。
*-- HIGH=写库/传票类(INSERT/UPDATE/DELETE/COMMIT WORK/ROLLBACK
*-- WORK/CALL TRANSACTION/OPEN DATASET/EXEC SQL/非只读 BAPI)
*-- MEDIUM=MODIFY(内表与 DB 表同词,保守计)/CLEAN=未检出。
*-- 词边界精确匹配,剥注释;粗扫定位,误报可由人工确认放行。
*-- 实现:上转→找字符串外注释截断点→REPLACE ALL 非词字符→分词。
*-- (教训:先拼词后上转+CONCATENATE 吞尾空格,会把整行熔成一个词)
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

TYPES: t_srcline(1024) TYPE c,
       BEGIN OF t_prog,
         name(40) TYPE c,
       END OF t_prog.
DATA: lt_seen  TYPE STANDARD TABLE OF t_prog WITH HEADER LINE,
      lt_src   TYPE STANDARD TABLE OF t_srcline WITH HEADER LINE,
      lt_tok   TYPE TABLE OF string WITH HEADER LINE,
      lv_prog  TYPE progname,
      lv_subc  TYPE reposrc-subc,
      lv_up    TYPE string,
      lv_body  TYPE string,
      lv_lvl   TYPE char6,
      lv_h     TYPE c,
      lv_m     TYPE c,
      lv_total TYPE i,
      lv_lno   TYPE i,
      lv_lc(6) TYPE c,
      lv_i     TYPE i,
      lv_n     TYPE i,
      lv_d     TYPE i,
      lv_j     TYPE i,
      lv_len   TYPE i,
      lv_cut   TYPE i,
      lv_q     TYPE i,
      lv_nxt   TYPE i,
      lv_c     TYPE c,
      lv_t2    TYPE string,
      lv_nx    TYPE string,
      lv_prev  TYPE string,
      lv_sfx   TYPE string,
      ls_risk  TYPE bapiret2.
CLEAR: ev_subrc, ev_risk_level, ev_message, lv_h, lv_m,
       lv_total, lv_prog.
REFRESH: et_risk, lt_seen.
CONDENSE iv_report.
TRANSLATE iv_report TO UPPER CASE.
SELECT SINGLE progname subc FROM reposrc
  INTO (lv_prog, lv_subc)
  WHERE progname = iv_report AND r3state = 'A'.
IF sy-subrc <> 0.
  ev_subrc = 8.
  CONCATENATE 'ERR: no report:' iv_report
    INTO ev_message SEPARATED BY space.
  RETURN.
ENDIF.
IF lv_subc <> '1'.
  ev_subrc = 8.
  ev_message = 'ERR: not type-1 executable'.
  RETURN.
ENDIF.
*-- 源码收集:主程序+INCLUDE,深度 2,≤30 个文件,≤20000 行
lt_seen-name = iv_report.
APPEND lt_seen.
lv_i = 1.
lv_d = 0.
DO 2 TIMES.
  ADD 1 TO lv_d.
  lv_n = LINES( lt_seen ).
  WHILE lv_i <= lv_n AND lv_i <= 30.
    READ TABLE lt_seen INDEX lv_i.
    lv_prog = lt_seen-name.
    REFRESH lt_src.
    READ REPORT lv_prog INTO lt_src[].
    IF sy-subrc <> 0.
      ADD 1 TO lv_i.
      CONTINUE.
    ENDIF.
    LOOP AT lt_src.
      lv_lno = sy-tabix.
      ADD 1 TO lv_total.
      IF lv_total > 20000.
        EXIT.
      ENDIF.
*     跳过整行注释(首个非空字符为 *)
      lv_j = 0.
      lv_len = STRLEN( lt_src ).
      WHILE lv_j < lv_len AND lt_src+lv_j(1) = ' '.
        ADD 1 TO lv_j.
      ENDWHILE.
      IF lv_j < lv_len AND lt_src+lv_j(1) = '*'.
        CONTINUE.
      ENDIF.
*     上转+找字符串外注释截断点(单引号奇偶判字符串)
      lv_up = lt_src.
      TRANSLATE lv_up TO UPPER CASE.
      lv_q = 0.
      lv_cut = lv_len.
      WHILE lv_j < lv_len.
        lv_c = lv_up+lv_j(1).
        IF lv_c = '"'.
          IF lv_q = 0.
            lv_cut = lv_j.
            EXIT.
          ENDIF.
        ELSEIF lv_c = ''''.
          IF lv_q = 0.
            lv_q = 1.
          ELSE.
            lv_q = 0.
          ENDIF.
        ENDIF.
        ADD 1 TO lv_j.
      ENDWHILE.
      IF lv_cut = 0.
        CONTINUE.
      ENDIF.
      lv_body = lv_up(lv_cut).
*     非词字符统一替换为空格(REPLACE ALL 不吞空格,分词才可靠)
      REPLACE ALL OCCURRENCES OF '.' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF ',' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF ':' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF ';' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '(' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF ')' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '[' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF ']' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '<' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '>' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '=' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '+' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '-' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '*' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '/' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '&' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '%' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '$' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '#' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '@' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '!' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '?' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '~' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '|' IN lv_body WITH ' '.
      REPLACE ALL OCCURRENCES OF '''' IN lv_body WITH ' '.
      CONDENSE lv_body.
      IF lv_body IS INITIAL.
        CONTINUE.
      ENDIF.
*     逐词判定(词边界由分词保证)
      REFRESH lt_tok.
      SPLIT lv_body AT ' ' INTO TABLE lt_tok.
      CLEAR lv_prev.
      LOOP AT lt_tok.
        lv_t2 = lt_tok.
        IF lv_t2 IS INITIAL.
          CONTINUE.
        ENDIF.
        lv_nxt = sy-tabix + 1.
        CLEAR lv_nx.
        READ TABLE lt_tok INDEX lv_nxt.
        IF sy-subrc = 0.
          lv_nx = lt_tok.
        ENDIF.
        IF lv_t2 = 'INSERT' OR lv_t2 = 'UPDATE'
            OR lv_t2 = 'DELETE'.
          lv_h = 'X'.
          CLEAR ls_risk.
          ls_risk-type = 'E'.
          ls_risk-id = lv_t2.
          ls_risk-number = lv_lno.
          WRITE lv_lno TO lv_lc.
          CONCATENATE lv_t2 'at line' lv_lc 'in' lv_prog
            INTO ls_risk-message SEPARATED BY space.
          IF LINES( et_risk ) < 50.
            APPEND ls_risk TO et_risk.
          ENDIF.
        ELSEIF lv_t2 = 'MODIFY'.
          lv_m = 'X'.
          CLEAR ls_risk.
          ls_risk-type = 'W'.
          ls_risk-id = 'MODIFY'.
          ls_risk-number = lv_lno.
          WRITE lv_lno TO lv_lc.
          CONCATENATE 'MODIFY at line' lv_lc 'in' lv_prog
            INTO ls_risk-message SEPARATED BY space.
          IF LINES( et_risk ) < 50.
            APPEND ls_risk TO et_risk.
          ENDIF.
        ELSEIF lv_t2 = 'WORK' AND lv_prev = 'COMMIT'.
          lv_h = 'X'.
          CLEAR ls_risk.
          ls_risk-type = 'E'.
          ls_risk-id = 'COMMIT_WORK'.
          ls_risk-number = lv_lno.
          WRITE lv_lno TO lv_lc.
          CONCATENATE 'COMMIT WORK at line' lv_lc 'in' lv_prog
            INTO ls_risk-message SEPARATED BY space.
          IF LINES( et_risk ) < 50.
            APPEND ls_risk TO et_risk.
          ENDIF.
        ELSEIF lv_t2 = 'WORK' AND lv_prev = 'ROLLBACK'.
          lv_h = 'X'.
          CLEAR ls_risk.
          ls_risk-type = 'E'.
          ls_risk-id = 'ROLLBACK_WORK'.
          ls_risk-number = lv_lno.
          WRITE lv_lno TO lv_lc.
          CONCATENATE 'ROLLBACK WORK at line' lv_lc 'in' lv_prog
            INTO ls_risk-message SEPARATED BY space.
          IF LINES( et_risk ) < 50.
            APPEND ls_risk TO et_risk.
          ENDIF.
        ELSEIF lv_t2 = 'TRANSACTION' AND lv_prev = 'CALL'.
          lv_h = 'X'.
          CLEAR ls_risk.
          ls_risk-type = 'E'.
          ls_risk-id = 'CALL_TRANSACTION'.
          ls_risk-number = lv_lno.
          WRITE lv_lno TO lv_lc.
          CONCATENATE 'CALL TRANSACTION at line' lv_lc 'in'
            lv_prog INTO ls_risk-message SEPARATED BY space.
          IF LINES( et_risk ) < 50.
            APPEND ls_risk TO et_risk.
          ENDIF.
        ELSEIF lv_t2 = 'DATASET' AND lv_prev = 'OPEN'.
          lv_h = 'X'.
          CLEAR ls_risk.
          ls_risk-type = 'E'.
          ls_risk-id = 'OPEN_DATASET'.
          ls_risk-number = lv_lno.
          WRITE lv_lno TO lv_lc.
          CONCATENATE 'OPEN DATASET at line' lv_lc 'in' lv_prog
            INTO ls_risk-message SEPARATED BY space.
          IF LINES( et_risk ) < 50.
            APPEND ls_risk TO et_risk.
          ENDIF.
        ELSEIF lv_t2 = 'SQL' AND lv_prev = 'EXEC'.
          lv_h = 'X'.
          CLEAR ls_risk.
          ls_risk-type = 'E'.
          ls_risk-id = 'EXEC_SQL'.
          ls_risk-number = lv_lno.
          WRITE lv_lno TO lv_lc.
          CONCATENATE 'EXEC SQL at line' lv_lc 'in' lv_prog
            INTO ls_risk-message SEPARATED BY space.
          IF LINES( et_risk ) < 50.
            APPEND ls_risk TO et_risk.
          ENDIF.
        ELSEIF lv_t2 = 'FUNCTION' AND lv_prev = 'CALL'
            AND lv_nx CP 'BAPI_*'.
          lv_sfx = lv_nx+5.
          IF lv_sfx CP 'GET*' OR lv_sfx CP 'LIST*'
              OR lv_sfx CP 'READ*' OR lv_sfx CP 'EXISTS*'
              OR lv_sfx CP 'DETAIL*' OR lv_sfx CP 'GETLIST*'.
*           只读类 BAPI:不算风险
          ELSE.
            lv_h = 'X'.
            CLEAR ls_risk.
            ls_risk-type = 'E'.
            ls_risk-id = 'BAPI'.
            ls_risk-number = lv_lno.
            WRITE lv_lno TO lv_lc.
            CONCATENATE 'BAPI call' lv_nx 'at line' lv_lc
              INTO ls_risk-message SEPARATED BY space.
            IF LINES( et_risk ) < 50.
              APPEND ls_risk TO et_risk.
            ENDIF.
          ENDIF.
        ELSEIF lv_t2 = 'INCLUDE'.
*         登记 INCLUDE(深度 2 收集,≤30 文件;剔 STRUCTURE/TYPE)
          IF lv_nx <> 'STRUCTURE' AND lv_nx <> 'TYPE'
              AND lv_nx IS NOT INITIAL AND LINES( lt_seen ) < 30.
            READ TABLE lt_seen WITH KEY name = lv_nx.
            IF sy-subrc <> 0.
              CLEAR lt_seen.
              lt_seen-name = lv_nx.
              APPEND lt_seen.
            ENDIF.
          ENDIF.
        ENDIF.
        lv_prev = lv_t2.
      ENDLOOP.
    ENDLOOP.
    ADD 1 TO lv_i.
  ENDWHILE.
ENDDO.
IF lv_h = 'X'.
  ev_risk_level = 'HIGH'.
ELSEIF lv_m = 'X'.
  ev_risk_level = 'MEDIUM'.
ELSE.
  ev_risk_level = 'CLEAN'.
  ev_message = 'NOTE: no write-op keyword found'.
ENDIF.
ENDFUNCTION.
