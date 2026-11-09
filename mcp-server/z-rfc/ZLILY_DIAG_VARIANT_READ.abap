FUNCTION zlily_diag_variant_read.
*"--------------------------------------------------------------------
*"*"局部接口：
*"  IMPORTING
*"     VALUE(IV_FUNCNAME) TYPE  RS38L_FNAM
*"     VALUE(IV_NUMMER) TYPE  CHAR4
*"  EXPORTING
*"     VALUE(EV_RESULT) TYPE  STRING
*"     VALUE(EV_ERROR) TYPE  STRING
*"     VALUE(EV_FOUND) TYPE  CHAR1
*"--------------------------------------------------------------------
* 通用变式解码器:GENERATE SUBROUTINE POOL + ZCL_JSON
  DATA: lv_pname TYPE pname,
        lv_grp   TYPE c LENGTH 30,
        lt_imp   TYPE TABLE OF rsimp,
        lt_tab   TYPE TABLE OF rstbl,
        ls_imp   TYPE rsimp,
        ls_tab   TYPE rstbl,
        lt_src   TYPE TABLE OF string,
        lv_l     TYPE string,
        lv_prog  TYPE string,
        lv_msg   TYPE string,
        lv_json  TYPE string,
        lv_cnt   TYPE i,
        lv_p     TYPE string,
        lv_t     TYPE string.

  SELECT SINGLE pname INTO lv_pname FROM tfdir
    WHERE funcname = iv_funcname.
  IF sy-subrc <> 0.
    ev_error = 'func not in tfdir'.
    RETURN.
  ENDIF.
  lv_grp = lv_pname+4.

  CALL FUNCTION 'FUNCTION_IMPORT_INTERFACE'
    EXPORTING
      funcname               = iv_funcname
    TABLES
      import_parameter       = lt_imp
      tables_parameter       = lt_tab
    EXCEPTIONS
      error_message          = 1
      OTHERS                 = 2.
  IF sy-subrc <> 0.
    ev_error = 'cannot read interface'.
    RETURN.
  ENDIF.

  DESCRIBE TABLE lt_imp LINES lv_cnt.
  IF lv_cnt = 0 AND lt_tab[] IS INITIAL.
    ev_error = 'no params'.
    RETURN.
  ENDIF.

  APPEND 'PROGRAM.' TO lt_src.
  APPEND 'TYPES: BEGIN OF ty_k,' TO lt_src.
  APPEND '  a TYPE c LENGTH 30,' TO lt_src.
  APPEND '  p TYPE c LENGTH 30,' TO lt_src.
  APPEND '  d TYPE c LENGTH 30,' TO lt_src.
  APPEND '  s TYPE c LENGTH 1,' TO lt_src.
  APPEND 'END OF ty_k.' TO lt_src.

  LOOP AT lt_imp INTO ls_imp.
    CHECK NOT ls_imp-typ IS INITIAL.
    lv_p = ls_imp-parameter.
    lv_t = ls_imp-typ.
    CONCATENATE 'DATA' lv_p 'TYPE' lv_t '.'
      INTO lv_l SEPARATED BY space.
    APPEND lv_l TO lt_src.
  ENDLOOP.

  LOOP AT lt_tab INTO ls_tab.
    CHECK NOT ls_tab-dbstruct IS INITIAL.
    lv_p = ls_tab-parameter.
    lv_t = ls_tab-dbstruct.
    CONCATENATE 'DATA' lv_p 'TYPE TABLE OF' lv_t '.'
      INTO lv_l SEPARATED BY space.
    APPEND lv_l TO lt_src.
  ENDLOOP.

  APPEND 'DATA: lv_k TYPE ty_k.' TO lt_src.
  APPEND 'DATA: lv_j TYPE string.' TO lt_src.
  APPEND 'DATA: lo TYPE REF TO zcl_json.' TO lt_src.

  APPEND 'FORM r USING pa pp pn.' TO lt_src.
  APPEND '  lv_k-a = pa.' TO lt_src.
  APPEND '  lv_k-p = pp.' TO lt_src.
  APPEND '  lv_k-d = pn.' TO lt_src.

  APPEND '  IMPORT' TO lt_src.
  LOOP AT lt_imp INTO ls_imp.
    CHECK NOT ls_imp-typ IS INITIAL.
    APPEND ls_imp-parameter TO lt_src.
  ENDLOOP.
  LOOP AT lt_tab INTO ls_tab.
    CHECK NOT ls_tab-dbstruct IS INITIAL.
    APPEND ls_tab-parameter TO lt_src.
  ENDLOOP.
  APPEND '    FROM DATABASE eufunc(fl) ID lv_k.'
    TO lt_src.

  APPEND '  DATA: BEGIN OF ls_a,' TO lt_src.
  LOOP AT lt_imp INTO ls_imp.
    CHECK NOT ls_imp-typ IS INITIAL.
    lv_p = ls_imp-parameter.
    lv_t = ls_imp-typ.
    CONCATENATE ls_p 'TYPE' lv_t ','
      INTO lv_l SEPARATED BY space.
    APPEND lv_l TO lt_src.
  ENDLOOP.
  LOOP AT lt_tab INTO ls_tab.
    CHECK NOT ls_tab-dbstruct IS INITIAL.
    lv_p = ls_tab-parameter.
    lv_t = ls_tab-dbstruct.
    CONCATENATE lv_p 'TYPE TABLE OF' lv_t ','
      INTO lv_l SEPARATED BY space.
    APPEND lv_l TO lt_src.
  ENDLOOP.
  APPEND '  END OF ls_a.' TO lt_src.

  LOOP AT lt_imp INTO ls_imp.
    CHECK NOT ls_imp-typ IS INITIAL.
    lv_p = ls_imp-parameter.
    CONCATENATE '  ls_a-' lv_p ' =' space lv_p '.'
      INTO lv_l.
    APPEND lv_l TO lt_src.
  ENDLOOP.
  LOOP AT lt_tab INTO ls_tab.
    CHECK NOT ls_tab-dbstruct IS INITIAL.
    lv_p = ls_tab-parameter.
    CONCATENATE '  ls_a-' lv_p '[] =' space lv_p '[].'
      INTO lv_l.
    APPEND lv_l TO lt_src.
  ENDLOOP.

  APPEND '  CREATE OBJECT lo.' TO lt_src.
  APPEND '  CALL METHOD lo->serialize' TO lt_src.
  APPEND '    EXPORTING data = ls_a' TO lt_src.
  APPEND '    RECEIVING r_json = lv_j.' TO lt_src.
  CONCATENATE '  EXPORT lv_j TO MEMORY ID'
    '''ZLILY_VR''.' INTO lv_l SEPARATED BY space.
  APPEND lv_l TO lt_src.
  APPEND 'ENDFORM.' TO lt_src.

  GENERATE SUBROUTINE POOL lt_src NAME lv_prog
    MESSAGE lv_msg.
  IF sy-subrc <> 0.
    CONCATENATE 'gen err:' lv_msg INTO ev_error
      SEPARATED BY space.
    RETURN.
  ENDIF.

  PERFORM r IN PROGRAM (lv_prog)
    USING lv_grp iv_funcname iv_nummer.
  IMPORT lv_j TO lv_json FROM MEMORY ID 'ZLILY_VR'.
  IF sy-subrc = 0.
    ev_result = lv_json.
    ev_found = 'X'.
  ELSE.
    ev_error = 'no data in memory'.
  ENDIF.
  FREE MEMORY ID 'ZLILY_VR'.

ENDFUNCTION.
