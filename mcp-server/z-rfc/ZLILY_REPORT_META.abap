FUNCTION ZLILY_REPORT_META.
*"----------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_REPORT) TYPE  CHAR40
*"     VALUE(IV_ACTION) TYPE  CHAR1 DEFAULT 'P'
*"     VALUE(IV_VARIANT) TYPE  VARIANT
*"  EXPORTING
*"     VALUE(EV_SUBRC) TYPE  SYSUBRC
*"     VALUE(EV_MESSAGE) TYPE  BAPI_MSG
*"  TABLES
*"      ET_PARAMS STRUCTURE  RSPARAMS
*"      ET_VARIANTS STRUCTURE  VARID
*"----------------------------------------------------------------------
*-- 白名单闸:ZMMT_CONFIG/KEY1=ZLILY_WHITELIST,逗号分隔 --*
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
  ev_subrc = 4.
  ev_message = 'ERR: caller not in whitelist'.
  RETURN.
ENDIF.
*-- 闸结束 --*
DATA lv_prog TYPE progname.
CLEAR: ev_subrc, ev_message.
CONDENSE iv_report.
TRANSLATE iv_report TO UPPER CASE.
IF iv_report IS INITIAL.
  ev_subrc = 4.
  ev_message = 'ERR: report blank'.
  RETURN.
ENDIF.
SELECT SINGLE progname FROM reposrc INTO lv_prog
  WHERE progname = iv_report AND r3state = 'A'.
IF sy-subrc <> 0.
  ev_subrc = 4.
  CONCATENATE 'ERR: no report:' iv_report
    INTO ev_message SEPARATED BY space.
  RETURN.
ENDIF.
CASE iv_action.
  WHEN 'P'.
    CALL FUNCTION 'RS_REFRESH_FROM_SELECTOPTIONS'
      EXPORTING
        curr_report     = iv_report
      TABLES
        selection_table = et_params
      EXCEPTIONS
        not_found       = 1
        OTHERS          = 2.
    IF sy-subrc <> 0.
      ev_subrc = 4 + sy-subrc.
      ev_message = 'ERR: get selopt'.
    ENDIF.
  WHEN 'V'.
    SELECT * FROM varid INTO TABLE et_variants
      WHERE report = iv_report.
  WHEN 'C'.
    IF iv_variant IS INITIAL.
      ev_subrc = 4.
      ev_message = 'ERR: need variant'.
      RETURN.
    ENDIF.
    CONDENSE iv_variant.
    TRANSLATE iv_variant TO UPPER CASE.
    CALL FUNCTION 'RS_VARIANT_CONTENTS'
      EXPORTING
        report               = iv_report
        variant              = iv_variant
      TABLES
        valutab              = et_params
      EXCEPTIONS
        variant_non_existent = 1
        variant_obsolete     = 2
        OTHERS               = 3.
    IF sy-subrc <> 0.
      ev_subrc = 4 + sy-subrc.
      ev_message = 'ERR: variant failed'.
    ENDIF.
  WHEN OTHERS.
    ev_subrc = 4.
    ev_message = 'ERR: bad action'.
ENDCASE.




ENDFUNCTION.
