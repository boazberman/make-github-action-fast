'use strict';

const fs = require('fs');
const path = require('path');
const child_process = require('child_process');

/**
 * Parse an environment / key-value string.
 * Supports KEY=VALUE pairs, comments (#), and stripping quotes.
 *
 * @param {string} content
 * @returns {Record<string, any>}
 */
function parseEnvFile(content) {
  const result = {};
  if (!content || typeof content !== 'string') {
    return result;
  }

  const lines = content.split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) {
      continue;
    }
    const eqIdx = line.indexOf('=');
    if (eqIdx === -1) {
      continue;
    }
    const key = line.slice(0, eqIdx).trim();
    let val = line.slice(eqIdx + 1).trim();

    // Strip wrapping quotes if present
    if (
      (val.startsWith('"') && val.endsWith('"') && val.length >= 2) ||
      (val.startsWith("'") && val.endsWith("'") && val.length >= 2)
    ) {
      val = val.slice(1, -1);
    }

    result[key] = val;
  }

  return result;
}

/**
 * Parse boolean input.
 * Evaluates to true if value (trimmed, lowercased) is 'true', '1', 'yes', or 'on'.
 *
 * @param {any} val
 * @param {boolean} defaultValue
 * @returns {boolean}
 */
function parseBool(val, defaultValue = false) {
  if (val === undefined || val === null || val === '') {
    return defaultValue;
  }
  if (typeof val === 'boolean') {
    return val;
  }
  const s = String(val).trim().toLowerCase();
  if (s === 'true' || s === '1' || s === 'yes' || s === 'on') {
    return true;
  }
  if (s === 'false' || s === '0' || s === 'no' || s === 'off') {
    return false;
  }
  return defaultValue;
}

/**
 * Validate and sanitize memory/disk size input (e.g. 50%, 4G, 512M).
 *
 * @param {string} val
 * @param {string} defaultValue
 * @returns {string}
 */
function sanitizeSize(val, defaultValue = '50%') {
  if (typeof val !== 'string') {
    return defaultValue;
  }
  const trimmed = val.trim();
  if (!trimmed) {
    return defaultValue;
  }
  if (/^[0-9]+(\.[0-9]+)?(%|[KMGT]B?)?$/i.test(trimmed)) {
    return trimmed.toUpperCase();
  }
  return defaultValue;
}

/**
 * Validate tmpfs-paths.
 * Leading '~/' expands to runnerHome.
 * Must be absolute. Rejects relative paths, paths under GITHUB_WORKSPACE,
 * and system paths: '/', '/proc', '/sys', '/dev', '/run', '/boot', '/etc', '/usr', '/var/lib/docker', and '$HOME' itself.
 *
 * @param {string} input - Comma-separated paths
 * @param {string} [runnerHome]
 * @param {string} [workspace]
 * @returns {{ valid: string[], rejected: Array<{ path: string, reason: string }> }}
 */
function validateTmpfsPaths(input, runnerHome = '', workspace = '') {
  const result = {
    valid: [],
    rejected: [],
  };

  if (!input || typeof input !== 'string') {
    return result;
  }

  const rawPaths = input.split(',').map(p => p.trim()).filter(Boolean);
  const homeNorm = runnerHome ? path.posix.normalize(runnerHome.replace(/\\/g, '/')).replace(/\/+$/, '') : '';
  const wsNorm = workspace ? path.posix.normalize(workspace.replace(/\\/g, '/')).replace(/\/+$/, '') : '';

  const forbiddenSystem = new Set([
    '/',
    '/proc',
    '/sys',
    '/dev',
    '/run',
    '/boot',
    '/etc',
    '/usr',
    '/var/lib/docker',
  ]);

  const seen = new Set();

  for (const raw of rawPaths) {
    let resolved = raw.replace(/\\/g, '/');

    // Expand leading ~/ or ~
    if (resolved === '~') {
      resolved = homeNorm;
    } else if (resolved.startsWith('~/')) {
      resolved = homeNorm ? `${homeNorm}/${resolved.slice(2)}` : resolved.slice(1);
    }

    // Must be absolute
    if (!path.posix.isAbsolute(resolved)) {
      result.rejected.push({ path: raw, reason: 'relative paths are not allowed' });
      continue;
    }

    let normalized = path.posix.normalize(resolved);
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.slice(0, -1);
    }

    // Check $HOME itself
    if (homeNorm && normalized === homeNorm) {
      result.rejected.push({ path: raw, reason: '$HOME itself cannot be mounted over with tmpfs' });
      continue;
    }

    // Check system directories
    if (forbiddenSystem.has(normalized)) {
      result.rejected.push({ path: raw, reason: `system directory '${normalized}' is rejected` });
      continue;
    }

    // Check under workspace
    if (wsNorm && (normalized === wsNorm || normalized.startsWith(wsNorm + '/'))) {
      result.rejected.push({ path: raw, reason: `path under GITHUB_WORKSPACE ('${wsNorm}') is rejected` });
      continue;
    }

    if (!seen.has(normalized)) {
      seen.add(normalized);
      result.valid.push(normalized);
    }
  }

  return result;
}

/**
 * Compose LD_PRELOAD: prepend newLib once, deduplicating by basename.
 *
 * @param {string|undefined} existingPreload
 * @param {string} newLib
 * @returns {string}
 */
function composeLdPreload(existingPreload, newLib) {
  if (!newLib) {
    return existingPreload || '';
  }
  const cleanNew = newLib.trim();
  if (!cleanNew) {
    return existingPreload || '';
  }
  if (!existingPreload || !existingPreload.trim()) {
    return cleanNew;
  }

  const newBase = path.posix.basename(cleanNew.replace(/\\/g, '/'));
  const parts = existingPreload.split(':').map(p => p.trim()).filter(Boolean);
  const filtered = parts.filter(p => {
    const b = path.posix.basename(p.replace(/\\/g, '/'));
    return b !== newBase;
  });

  return [cleanNew, ...filtered].join(':');
}

/**
 * Compose ASAN_OPTIONS: append 'verify_asan_link_order=0' colon-separated if not present.
 *
 * @param {string|undefined} existingAsan
 * @returns {string}
 */
function composeAsanOptions(existingAsan) {
  const target = 'verify_asan_link_order=0';
  if (!existingAsan || !existingAsan.trim()) {
    return target;
  }
  const parts = existingAsan.split(':').map(p => p.trim()).filter(Boolean);
  if (parts.includes(target)) {
    return existingAsan;
  }
  return `${existingAsan}:${target}`;
}

/**
 * Compose git config environment variables (GIT_CONFIG_*).
 *
 * @param {Record<string, string|undefined>} env
 * @param {Array<[string, string]>} configs
 * @returns {Record<string, string>}
 */
function composeGitConfigEnv(env, configs) {
  const rawCount = env && env.GIT_CONFIG_COUNT;
  let count = parseInt(rawCount, 10);
  if (isNaN(count) || count < 0) {
    count = 0;
  }

  const result = {};
  for (let i = 0; i < configs.length; i++) {
    const idx = count + i;
    result[`GIT_CONFIG_KEY_${idx}`] = configs[i][0];
    result[`GIT_CONFIG_VALUE_${idx}`] = configs[i][1];
  }
  result.GIT_CONFIG_COUNT = String(count + configs.length);
  return result;
}

/**
 * Check if git version is >= 2.31.0.
 *
 * @param {string} versionOutput
 * @returns {boolean}
 */
function checkGitVersion(versionOutput) {
  if (!versionOutput || typeof versionOutput !== 'string') {
    return false;
  }
  const match = versionOutput.match(/git version\s+(\d+)\.(\d+)(?:\.(\d+))?/i);
  if (!match) {
    return false;
  }
  const major = parseInt(match[1], 10);
  const minor = parseInt(match[2], 10);
  if (major > 2) {
    return true;
  }
  if (major === 2 && minor >= 31) {
    return true;
  }
  return false;
}

/**
 * Escape markdown table cell content. Escapes '|' and flattens newlines.
 *
 * @param {any} text
 * @returns {string}
 */
function escapeMarkdown(text) {
  if (text === null || text === undefined) {
    return '';
  }
  return String(text).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
}

/**
 * Format bytes into human-readable string (KiB, MiB, GiB, etc.).
 *
 * @param {number} bytes
 * @param {number} decimals
 * @returns {string}
 */
function formatBytes(bytes, decimals = 1) {
  const b = Number(bytes);
  if (isNaN(b) || b <= 0) {
    return '0 B';
  }
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  const k = 1024;
  const i = Math.floor(Math.log(b) / Math.log(k));
  const unitIndex = Math.min(Math.max(0, i), units.length - 1);
  if (unitIndex === 0) {
    return `${Math.round(b)} B`;
  }
  const val = (b / Math.pow(k, unitIndex)).toFixed(decimals);
  return `${val} ${units[unitIndex]}`;
}

/**
 * Format number with comma separators.
 *
 * @param {number} num
 * @returns {string}
 */
function formatNumber(num) {
  const n = Number(num);
  if (isNaN(n)) {
    return '0';
  }
  return n.toLocaleString('en-US');
}

/**
 * Read file safely, returning string or null.
 *
 * @param {string} filePath
 * @returns {string|null}
 */
function safeReadFile(filePath) {
  try {
    if (filePath && fs.existsSync(filePath)) {
      return fs.readFileSync(filePath, 'utf8');
    }
  } catch {
    // Ignore read errors
  }
  return null;
}

/**
 * Append line `name=value\n` to a file.
 *
 * @param {string} filePath
 * @param {string} name
 * @param {string} value
 * @returns {boolean}
 */
function appendGithubFile(filePath, name, value) {
  if (!filePath) {
    return false;
  }
  try {
    fs.appendFileSync(filePath, `${name}=${value}\n`, 'utf8');
    return true;
  } catch {
    return false;
  }
}

/**
 * Append to GITHUB_ENV
 */
function appendGithubEnv(name, value) {
  return appendGithubFile(process.env.GITHUB_ENV, name, value);
}

/**
 * Append to GITHUB_OUTPUT
 */
function appendGithubOutput(name, value) {
  return appendGithubFile(process.env.GITHUB_OUTPUT, name, value);
}

/**
 * Append to GITHUB_STATE
 */
function appendGithubState(name, value) {
  return appendGithubFile(process.env.GITHUB_STATE, name, value);
}

/**
 * Append markdown to GITHUB_STEP_SUMMARY
 *
 * @param {string} content
 * @returns {boolean}
 */
function appendGithubSummary(content) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (!summaryPath) {
    return false;
  }
  try {
    fs.appendFileSync(summaryPath, content + '\n', 'utf8');
    return true;
  } catch {
    return false;
  }
}

/**
 * Run root script with bash / sudo / unprivileged strategy.
 * Timeout: 60s.
 *
 * @param {string} scriptPath
 * @param {string[]} args
 * @param {Record<string, string>} envVars
 * @param {object} [options]
 * @returns {child_process.SpawnSyncReturns<string>}
 */
function runRootScript(scriptPath, args = [], envVars = {}, options = {}) {
  const isRoot = typeof process.getuid === 'function' && process.getuid() === 0;
  let canSudo = false;

  if (!isRoot) {
    try {
      const sudoCheck = child_process.spawnSync('sudo', ['-n', 'true'], {
        stdio: 'ignore',
        timeout: 5000,
      });
      canSudo = sudoCheck.status === 0;
    } catch {
      canSudo = false;
    }
  }

  let command;
  let cmdArgs;
  const spawnEnv = { ...process.env, ...envVars };

  if (isRoot) {
    command = 'bash';
    cmdArgs = [scriptPath, ...args];
  } else if (canSudo) {
    command = 'sudo';
    const envArgs = Object.entries(envVars).map(([k, v]) => `${k}=${v}`);
    cmdArgs = ['-n', 'env', ...envArgs, 'bash', scriptPath, ...args];
  } else {
    command = 'bash';
    cmdArgs = [scriptPath, ...args];
  }

  let res;
  try {
    res = child_process.spawnSync(command, cmdArgs, {
      cwd: '/',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: options.timeout || 60000,
      maxBuffer: 16 * 1024 * 1024,
      env: spawnEnv,
      encoding: 'utf8',
    });
  } catch (err) {
    res = {
      status: -1,
      stdout: '',
      stderr: err && err.message ? err.message : String(err),
      error: err,
    };
  }

  if (res.stdout) {
    process.stdout.write(res.stdout);
  }
  if (res.stderr) {
    process.stderr.write(res.stderr);
  }

  return res;
}

module.exports = {
  parseEnvFile,
  parseBool,
  sanitizeSize,
  validateTmpfsPaths,
  composeLdPreload,
  composeAsanOptions,
  composeGitConfigEnv,
  checkGitVersion,
  escapeMarkdown,
  formatBytes,
  formatNumber,
  safeReadFile,
  appendGithubFile,
  appendGithubEnv,
  appendGithubOutput,
  appendGithubState,
  appendGithubSummary,
  runRootScript,
};
