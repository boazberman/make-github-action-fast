'use strict';

const fs = require('fs');
const path = require('path');
const child_process = require('child_process');

/**
 * Parse an environment / key-value string.
 * Supports KEY=VALUE pairs. Repeated keys 'SPILL_BOUND' and 'SPILL_SKIPPED'
 * accumulate into arrays. Other keys are last-wins.
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

    if (key === 'SPILL_BOUND' || key === 'SPILL_SKIPPED') {
      if (!Array.isArray(result[key])) {
        result[key] = [];
      }
      result[key].push(val);
    } else {
      result[key] = val;
    }
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
 * Validate and sanitize zram-size.
 * Matches ^[0-9]+(\.[0-9]+)?[KMGT]?$ case-insensitively, returning uppercase;
 * otherwise defaults to '6G'.
 *
 * @param {string} val
 * @returns {string}
 */
function sanitizeZramSize(val) {
  if (typeof val !== 'string') {
    return '6G';
  }
  const trimmed = val.trim();
  if (/^[0-9]+(\.[0-9]+)?[KMGT]?$/i.test(trimmed)) {
    return trimmed.toUpperCase();
  }
  return '6G';
}

/**
 * Validate and sanitize spill-dirs.
 * Comma-joined sanitized list: trim, strip leading './' and trailing '/',
 * drop empty, drop absolute paths, drop anything containing a '..' segment,
 * drop chars outside [A-Za-z0-9._/@+-].
 *
 * @param {string} val
 * @returns {string}
 */
function sanitizeSpillDirs(val) {
  if (typeof val !== 'string' || !val) {
    return '';
  }
  const parts = val.split(',');
  const validChars = /^[A-Za-z0-9._/@+-]+$/;
  const sanitized = [];

  for (const part of parts) {
    let s = part.trim();
    if (!s) {
      continue;
    }

    // Drop absolute paths (/..., \..., C:\...)
    if (s.startsWith('/') || s.startsWith('\\') || /^[a-zA-Z]:[\\/]/.test(s)) {
      continue;
    }

    // Strip leading './' or '.\'
    while (s.startsWith('./') || s.startsWith('.\\')) {
      s = s.slice(2);
    }

    // Strip trailing '/' or '\'
    while (s.endsWith('/') || s.endsWith('\\')) {
      s = s.slice(0, -1);
    }

    if (!s) {
      continue;
    }

    // Drop anything containing a '..' segment
    const segments = s.split(/[\\/]/);
    if (segments.some(seg => seg === '..' || seg.includes('..'))) {
      continue;
    }

    // Drop strings with characters outside [A-Za-z0-9._/@+-]
    if (!validChars.test(s)) {
      continue;
    }

    sanitized.push(s);
  }

  return sanitized.join(',');
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
 * Get input value from environment with fallback.
 * Checks INPUT_<NAME> and INPUT_<NAME_UNDERSCORED>.
 *
 * @param {string} name
 * @param {string} defaultValue
 * @returns {string}
 */
function getInput(name, defaultValue) {
  const upper = name.toUpperCase();
  const rawHyphen = process.env['INPUT_' + upper];
  if (rawHyphen !== undefined && rawHyphen !== null && rawHyphen.trim() !== '') {
    return rawHyphen.trim();
  }
  const rawUnderscore = process.env['INPUT_' + upper.replace(/-/g, '_')];
  if (rawUnderscore !== undefined && rawUnderscore !== null && rawUnderscore.trim() !== '') {
    return rawUnderscore.trim();
  }
  return defaultValue;
}

/**
 * Run root script with bash / sudo / unprivileged strategy.
 *
 * Strategy:
 * 1. if process.getuid() === 0 -> bash <script> <args> with env merged
 * 2. else if sudo exists and `sudo -n true` exits 0 -> sudo -n env K1=V1 ... bash <script> <args>
 * 3. else -> bash <script> <args> unprivileged
 *
 * @param {string} scriptPath
 * @param {string[]} args
 * @param {Record<string, string>} envVars
 * @returns {child_process.SpawnSyncReturns<string>}
 */
function runRootScript(scriptPath, args = [], envVars = {}) {
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
  let spawnEnv = { ...process.env, ...envVars };

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
      timeout: 120000,
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
  sanitizeZramSize,
  sanitizeSpillDirs,
  escapeMarkdown,
  formatBytes,
  formatNumber,
  safeReadFile,
  appendGithubFile,
  appendGithubEnv,
  appendGithubOutput,
  appendGithubState,
  appendGithubSummary,
  getInput,
  runRootScript,
};
