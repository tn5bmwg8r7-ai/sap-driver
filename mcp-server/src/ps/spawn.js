// spawn.js — spawn-per-call bridge to dispatcher.ps1.
// Sends {system,password,steps} via stdin (password never on CLI args), parses
// the last JSON line on stdout. One short-lived PS process per call.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dispatcherPs1 = path.join(__dirname, 'dispatcher.ps1');

/**
 * @param {object} opts
 * @param {string} opts.system
 * @param {string} opts.password
 * @param {Array<{id:string,function:string,import?:object,tables?:object}>} opts.steps
 * @param {number} [opts.timeoutMs=90000]
 * @returns {Promise<{ok:boolean, system?:string, results?:object, code?:string, message?:string}>}
 */
export function runSteps(opts) {
  const { system, password, steps, client, user, language } = opts;
  const systemsPath = opts.systemsPath || process.env.SAP_MCP_SYSTEMS;
  const sapBin = opts.sapBin || process.env.SAP_MCP_BIN;
  const timeoutMs = opts.timeoutMs || 90000;

  return new Promise((resolve, reject) => {
    const payload = JSON.stringify({
      system, password, steps,
      client: client || undefined,
      user: user || undefined,
      language: language || undefined,
    });
    const ps = spawn('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', dispatcherPs1,
    ], {
      env: { ...process.env, SAP_MCP_SYSTEMS: systemsPath, SAP_MCP_BIN: sapBin },
      windowsHide: true,
    });

    let stdout = '';
    let stderr = '';
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { ps.kill('SIGKILL'); } catch {}
      reject(new Error(`DISPATCHER_TIMEOUT after ${timeoutMs}ms`));
    }, timeoutMs);

    ps.stdout.on('data', (d) => { stdout += d.toString('utf8'); });
    ps.stderr.on('data', (d) => { stderr += d.toString('utf8'); });

    ps.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const lines = stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
      // pick the last line that parses as JSON (dispatcher prints one line; tolerate stray output)
      let parsed = null;
      for (let i = lines.length - 1; i >= 0; i--) {
        try { parsed = JSON.parse(lines[i]); break; } catch {}
      }
      if (parsed) {
        if (parsed.ok === false) resolve(parsed);      // structured error from dispatcher
        else resolve(parsed);
      } else {
        reject(new Error(
          `DISPATCHER_NO_JSON (exit=${code}) stderr=${stderr.trim().slice(0, 800)} stdout_tail=${stdout.slice(-400)}`
        ));
      }
    });

    ps.on('error', (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error(`DISPATCHER_SPAWN_ERROR: ${e.message}`));
    });

    // password flows via stdin only
    ps.stdin.write(payload + '\n');
    ps.stdin.end();
  });
}
