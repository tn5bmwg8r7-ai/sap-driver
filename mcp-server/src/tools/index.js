// tools/index.js — tool registry. Each tool exports:
//   { name, description, schema (ZodRawShape), allowedEnvs, opClass,
//     needsRfc?(default true), requiresSystem?(default true), underlying?(string[]), run(args, ctx) }
import sapConnect from './sap_connect.js';
import sapEnvStatus from './sap_env_status.js';
import sapHelp from './sap_help.js';
import sapQuery from './sap_query.js';
import sapObjectMeta from './sap_object_meta.js';
import sapFmRead from './sap_fm_read.js';
import sapProgRead from './sap_prog_read.js';
import sapVariantRead from './sap_variant_read.js';
import sapVariantWrite from './sap_variant_write.js';
import sapFmExec from './sap_fm_exec.js';
import sapTestdataSave from './sap_testdata_save.js';
import sapTestdataLoad from './sap_testdata_load.js';
import sapTestdataList from './sap_testdata_list.js';
import sapDevCreate from './sap_dev_create.js';
import sapDevDelete from './sap_dev_delete.js';
import sapDevTr from './sap_dev_tr.js';
import sapDevTrPut from './sap_dev_tr_put.js';
import sapDeepSeek from './sap_deepseek.js';

export const TOOLS = [
  sapConnect,
  sapEnvStatus,
  sapHelp,
  sapQuery,
  sapObjectMeta,
  sapFmRead,
  sapProgRead,
  sapVariantRead,
  sapVariantWrite,
  sapFmExec,
  sapTestdataSave,
  sapTestdataLoad,
  sapTestdataList,
  sapDevCreate,
  sapDevDelete,
  sapDevTr,
  sapDevTrPut,
  sapDeepSeek,
];
