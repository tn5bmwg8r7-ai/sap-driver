FUNCTION zlily_dev_tr_put.
*"----------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_ORDER) TYPE  TRKORR
*"     VALUE(IV_PGMID) TYPE  PGMID DEFAULT 'R3TR'
*"     VALUE(IV_OBJECT) TYPE  TROBJTYPE
*"     VALUE(IV_OBJ_NAME) TYPE  TROBJ_NAME
*"  EXPORTING
*"     VALUE(EV_ERROR) TYPE  STRING
*"     VALUE(EV_MSG) TYPE  STRING
*"----------------------------------------------------------------------
* 用途:Z/Y 对象挂 TR 的通用 RFC 包装器(TR_OBJECT_INSERT 非 RFC 的替代通道)。
* v3(2026-09-16 实测定案):
*  1) R3TR 且 TADIR 缺注册(TRINT 会静默空转假 OK)→ RS_CORR_INSERT 注册+挂请求
*     (SUPPRESS_DIALOG 无弹窗;FUNC 的 devclass 从所属函数组 TADIR 推导)
*  2) 其余(TADIR 已在的 R3TR / LIMU)→ TRINT_OBJECTS_CHECK_AND_INSERT 裸键
*     (本 ECC 表参是 CHANGING CT_KO200/CT_E071K,非 TABLES WT_*)
*  3) 成功后必须显式 COMMIT WORK(实爆案例:缺 COMMIT 随会话回滚)
*  4) 终判以 E071 实查为准(兼容挂任务号),杜绝假 OK
* Z/Y 护栏两层:MCP 侧 isCustomerNamespace + 本函数再校验。
* 本 FM 归 ZFG_LILY_DEV 组(dev-write 类,DVP-only,永不传 PRD)。

  DATA: lt_ko200 TYPE TABLE OF ko200,
        ls_ko200 TYPE ko200,
        lt_e071k TYPE TABLE OF e071k,
        lv_name  TYPE string,
        lv_txt   TYPE string,
        lv_devcl TYPE tadir-devclass,
        lv_pname TYPE tfdir-pname,
        lv_grp   TYPE string,
        lv_hit   TYPE e071-obj_name,
        lv_rsreg TYPE c.

  CLEAR: ev_error, ev_msg.

* --- Z/Y 护栏第二层:标准/增强对象绝不触碰 ---
  lv_name = iv_obj_name.
  CONDENSE lv_name.
  TRANSLATE lv_name TO UPPER CASE.
  IF lv_name(1) <> 'Z' AND lv_name(1) <> 'Y'.
    CONCATENATE 'ERR:not customer namespace:' lv_name
      INTO ev_error SEPARATED BY space.
    RETURN.
  ENDIF.

  CLEAR lv_rsreg.

  IF iv_pgmid = 'R3TR'.
    SELECT SINGLE obj_name FROM tadir INTO lv_hit
      WHERE pgmid = 'R3TR' AND object = iv_object AND obj_name = lv_name.
    IF sy-subrc <> 0.
*     --- TADIR 缺注册:RS_CORR_INSERT 无弹窗 注册+锁+挂请求 ---
      CLEAR lv_devcl.
      IF iv_object = 'FUNC'.
        SELECT SINGLE pname FROM tfdir INTO lv_pname WHERE funcname = lv_name.
        IF sy-subrc = 0.
          lv_grp = lv_pname+4.
          CONDENSE lv_grp.
          SELECT SINGLE devclass FROM tadir INTO lv_devcl
            WHERE pgmid = 'R3TR' AND object = 'FUGR' AND obj_name = lv_grp.
        ENDIF.
      ENDIF.
      IF lv_devcl IS INITIAL.
        CONCATENATE 'ERR:no TADIR/devclass for' lv_name
          INTO ev_error SEPARATED BY space.
        RETURN.
      ENDIF.
      CALL FUNCTION 'RS_CORR_INSERT'
        EXPORTING
          object                  = lv_name
          object_class            = iv_object
          mode                    = 'INSERT'
          global_lock             = 'X'
          devclass                = lv_devcl
          korrnum                 = iv_order
          author                  = sy-uname
          master_language         = '1'
          suppress_dialog         = 'X'
        EXCEPTIONS
          cancelled               = 1
          permission_failure      = 2
          unknown_objectclass     = 3
          OTHERS                  = 4.
      IF sy-subrc <> 0.
        IF sy-msgid IS NOT INITIAL.
          MESSAGE ID sy-msgid TYPE 'S' NUMBER sy-msgno
                  WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4 INTO lv_txt.
        ELSE.
          lv_txt = 'rs_corr_insert failed'.
        ENDIF.
        CONCATENATE 'ERR:' lv_txt INTO ev_error SEPARATED BY space.
        RETURN.
      ENDIF.
      COMMIT WORK.
      lv_rsreg = 'X'.
    ENDIF.
  ENDIF.

  IF lv_rsreg IS INITIAL.
*   --- 常规路径:KO200 裸键(只填三键;E071K 空) ---
    ls_ko200-pgmid    = iv_pgmid.
    ls_ko200-object   = iv_object.
    ls_ko200-obj_name = lv_name.
    APPEND ls_ko200 TO lt_ko200.

    CALL FUNCTION 'TRINT_OBJECTS_CHECK_AND_INSERT'
      EXPORTING
        iv_order           = iv_order
        iv_append_to_order = 'X'
      CHANGING
        ct_ko200           = lt_ko200
        ct_e071k           = lt_e071k
      EXCEPTIONS
        OTHERS             = 1.

    IF sy-subrc <> 0.
      IF sy-msgid IS NOT INITIAL.
        MESSAGE ID sy-msgid TYPE 'S' NUMBER sy-msgno
                WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4 INTO lv_txt.
      ELSE.
        lv_txt = 'check_and_insert failed'.
      ENDIF.
      CONCATENATE 'ERR:' lv_txt INTO ev_error SEPARATED BY space.
      RETURN.
    ENDIF.

    COMMIT WORK.
  ENDIF.

* --- 终判:E071 实查(兼容对象挂任务号;TRINT 空转在此现形) ---
  SELECT SINGLE obj_name FROM e071 INTO lv_hit
    WHERE obj_name = lv_name AND object = iv_object.
  IF sy-subrc <> 0.
    ev_error = 'ERR:not persisted in E071 (silent no-op)'.
    RETURN.
  ENDIF.

  CONCATENATE 'OK:' iv_order ':' iv_pgmid ':' iv_object ':' lv_name
    INTO ev_msg SEPARATED BY space.
ENDFUNCTION.
