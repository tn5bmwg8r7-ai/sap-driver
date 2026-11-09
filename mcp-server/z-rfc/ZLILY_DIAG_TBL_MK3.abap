FUNCTION ZLILY_DIAG_TBL_MK3.
*"----------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_TABLE_NAME) TYPE  TABNAME
*"     VALUE(IV_TABCLASS) TYPE  TABCLASS
*"     VALUE(IV_DDTEXT) TYPE  AS4TEXT
*"  EXPORTING
*"     VALUE(EV_ERROR) TYPE  CHAR255
*"  TABLES
*"      IT_FIELDS STRUCTURE  DD03P
*"  EXCEPTIONS
*"      DDIC_ERROR
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
  RAISE ddic_error.
ENDIF.
*-- 白名单闸结束 --*
DATA: ls_dd02v TYPE dd02v,
      lt_dd03p TYPE TABLE OF dd03p,
      ls_dd03p TYPE dd03p,
      ls_dtel  TYPE dd04v.
  ls_dd02v-tabname    = iv_table_name.
  ls_dd02v-ddlanguage = sy-langu.
  ls_dd02v-tabclass   = iv_tabclass.
  ls_dd02v-ddtext     = iv_ddtext.
  IF iv_tabclass = 'TRANSP'
     OR iv_tabclass = 'CLUSTER'
     OR iv_tabclass = 'POOL'.
    ls_dd02v-contflag = 'C'.
    ls_dd02v-exclass  = '1'.
  ENDIF.
  LOOP AT it_fields INTO ls_dd03p.
    IF ls_dd03p-position IS INITIAL.
      ls_dd03p-position = sy-tabix.
    ENDIF.
    IF ls_dd03p-rollname IS NOT INITIAL
       AND ls_dd03p-datatype IS INITIAL.
      CALL FUNCTION 'DDIF_DTEL_GET'
        EXPORTING
          name      = ls_dd03p-rollname
          langu     = sy-langu
        IMPORTING
          dd04v_wa  = ls_dtel
        EXCEPTIONS
          OTHERS    = 1.
      IF sy-subrc = 0.
       ls_dd03p-datatype = ls_dtel-datatype.
          ls_dd03p-leng     = ls_dtel-leng.
          ls_dd03p-decimals = ls_dtel-decimals.
          ls_dd03p-domname  = ls_dtel-domname.
      ENDIF.
    ENDIF.
    IF ls_dd03p-fieldname = 'MANDT'.
      ls_dd03p-datatype = 'CLNT'.
      ls_dd03p-leng     = '000003'.
      ls_dd03p-inttype  = 'C'.
      ls_dd03p-intlen   = '000006'.
    ENDIF.
    APPEND ls_dd03p TO lt_dd03p.
  ENDLOOP.
  CALL FUNCTION 'DDIF_TABL_PUT'
    EXPORTING
      name      = iv_table_name
      dd02v_wa  = ls_dd02v
    TABLES
      dd03p_tab = lt_dd03p
    EXCEPTIONS
      OTHERS    = 1.
  IF sy-subrc <> 0.
    MESSAGE ID sy-msgid TYPE sy-msgty NUMBER sy-msgno
            WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4 INTO ev_error.
    RAISE ddic_error.
  ENDIF.
  CALL FUNCTION 'DDIF_TABL_ACTIVATE'
    EXPORTING
      name   = iv_table_name
    EXCEPTIONS
      OTHERS = 2.
  COMMIT WORK.
ENDFUNCTION.
