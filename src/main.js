'use strict';

// Captured before any require() so the reported setup time includes module loading.
const T0 = Date.now();

const os = require('os');
const path = require('path');
const child_process = require('child_process');
const {
  parseEnvFile,
  parseBool,
  sanitizeZramSize,
  sanitizeSpillDirs,
  safeReadFile,
  appendGithubEnv,
  appendGithubOutput,
  appendGithubState,
  runRootScript,
} = require('./common');

/**
 * Parse inputs from environment variables.
 *
 * @param {Record<string, string>} [env]
 * @returns {Record<string, any>}
 */
function parseInputs(env = process.env) {
  function get(name, def) {
    const upper = name.toUpperCase();
    const rawHyphen = env['INPUT_' + upper];
    if (rawHyphen !== undefined && rawHyphen !== null && rawHyphen.trim() !== '') {
      return rawHyphen.trim();
    }
    const rawUnderscore = env['INPUT_' + upper.replace(/-/g, '_')];
    if (rawUnderscore !== undefined && rawUnderscore !== null && rawUnderscore.trim() !== '') {
      return rawUnderscore.trim();
    }
    return def;
  }

  const fsyncBypass = parseBool(get('fsync-bypass', 'true'), true);
  const pageCache = parseBool(get('page-cache-tuning', 'true'), true);
  const remount = parseBool(get('remount-fast', 'true'), true);
  const gitTuning = parseBool(get('git-tuning', 'true'), true);
  const zram = parseBool(get('zram-workspace', 'false'), false);
  const zramSize = sanitizeZramSize(get('zram-size', '6G'));
  const spillDirs = sanitizeSpillDirs(get('spill-dirs', 'node_modules,.cargo,.gradle,.venv,target'));
  const summary = parseBool(get('summary', 'true'), true);

  return {
    fsyncBypass,
    pageCache,
    remount,
    gitTuning,
    zram,
    zramSize,
    spillDirs,
    summary,
  };
}

/**
 * Best-effort git config tuning fallback for unprivileged runner user.
 *
 * @returns {boolean}
 */
function applyGitFallback() {
  const configs = [
    ['feature.manyFiles', 'true'],
    ['core.untrackedCache', 'true'],
    ['core.fscache', 'true'],
    ['pack.threads', '0'],
    ['index.threads', 'true'],
    ['checkout.workers', '0'],
    ['fetch.parallel', '0'],
    ['submodule.fetchJobs', '0'],
    ['gc.auto', '0'],
    ['maintenance.auto', 'false'],
    ['index.skipHash', 'false'],
  ];
  let success = true;
  for (const [k, v] of configs) {
    try {
      child_process.execFileSync('git', ['config', '--global', k, v], {
        stdio: 'ignore',
        timeout: 5000,
      });
    } catch {
      success = false;
    }
  }
  return success;
}

/**
 * Main action execution function.
 */
function run() {
  try {
    if (process.platform !== 'linux') {
      console.log(`::notice title=make-github-action-fast::Unsupported platform ${process.platform}; skipping (Linux runners only).`);
      return;
    }

    const inputs = parseInputs(process.env);
    const actionPath = path.resolve(__dirname, '..');
    const workspace = process.env.GITHUB_WORKSPACE || process.cwd();
    const stateFile = '/tmp/gh-fast-state.env';
    const metricsFile = '/tmp/gh-fast-metrics-start.env';
    const fallbackDir = path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'gh-fast');

    let uid = 1000;
    let gid = 1000;
    try {
      const info = os.userInfo();
      if (typeof info.uid === 'number') uid = info.uid;
      if (typeof info.gid === 'number') gid = info.gid;
    } catch {
      // Fallback to 1000:1000
    }

    const scriptEnv = {
      GHFAST_ACTION_PATH: actionPath,
      GHFAST_FSYNC_BYPASS: String(inputs.fsyncBypass),
      GHFAST_PAGE_CACHE: String(inputs.pageCache),
      GHFAST_REMOUNT: String(inputs.remount),
      GHFAST_GIT_TUNING: String(inputs.gitTuning),
      GHFAST_ZRAM: String(inputs.zram),
      GHFAST_ZRAM_SIZE: inputs.zramSize,
      GHFAST_SPILL_DIRS: inputs.spillDirs,
      GHFAST_WORKSPACE: workspace,
      GHFAST_UID: String(uid),
      GHFAST_GID: String(gid),
      GHFAST_STATE_FILE: stateFile,
      GHFAST_METRICS_FILE: metricsFile,
      GHFAST_LIB_FALLBACK_DIR: fallbackDir,
      GHFAST_START_EPOCH_MS: String(T0),
    };

    console.log('::group::make-github-action-fast setup');
    const setupScript = path.join(actionPath, 'src', 'setup-linux.sh');
    const scriptResult = runRootScript(setupScript, ['setup'], scriptEnv);
    console.log('::endgroup::');

    if (scriptResult.error) {
      console.log(`::warning title=make-github-action-fast::setup-linux.sh execution error: ${scriptResult.error.message}`);
    } else if (scriptResult.status !== 0) {
      console.log(`::warning title=make-github-action-fast::setup-linux.sh exited with code ${scriptResult.status}`);
    }

    // Read and parse state file
    const rawState = safeReadFile(stateFile);
    const state = parseEnvFile(rawState || '');

    // 1. Fsync bypass LD_PRELOAD handling
    if (state.FSYNC_BYPASS === 'active' && state.LD_PRELOAD_VALUE) {
      const existingPreload = process.env.LD_PRELOAD || '';
      let preloadVal = state.LD_PRELOAD_VALUE;
      if (existingPreload) {
        const parts = existingPreload.split(':');
        if (!parts.includes(state.LD_PRELOAD_VALUE)) {
          preloadVal = `${state.LD_PRELOAD_VALUE}:${existingPreload}`;
        } else {
          preloadVal = existingPreload;
        }
      }
      appendGithubEnv('LD_PRELOAD', preloadVal);
      appendGithubEnv('NOSYNC_ACTIVE', '1');
    }

    // 2. Git fallback if git-tuning enabled and setup script failed / didn't set it
    if (inputs.gitTuning && (state.GIT_TUNING === 'failed' || !state.GIT_TUNING)) {
      const fallbackSuccess = applyGitFallback();
      state.GIT_TUNING = fallbackSuccess ? 'global' : 'failed';
    }

    // 3. Save state for post step
    appendGithubState('start_ms', String(T0));
    appendGithubState('state_file', stateFile);
    appendGithubState('metrics_file', metricsFile);
    appendGithubState('summary', inputs.summary ? 'true' : 'false');
    appendGithubState('zram', state.ZRAM || (inputs.zram ? 'active' : 'disabled'));
    appendGithubState('privileged', state.PRIVILEGED || 'false');

    // 4. Set action outputs
    const setupMs = Date.now() - T0;
    appendGithubOutput('setup-time-ms', String(setupMs));
    appendGithubOutput('fsync-bypass', state.FSYNC_BYPASS || (inputs.fsyncBypass ? 'failed' : 'disabled'));
    appendGithubOutput('zram-device', state.ZRAM_DEV || '');

    // 5. Concise log line
    const fsyncStr = state.FSYNC_BYPASS || (inputs.fsyncBypass ? 'failed' : 'disabled');
    const cacheStr = state.PAGE_CACHE || (inputs.pageCache ? 'failed' : 'disabled');
    let remountStr = state.REMOUNT || (inputs.remount ? 'failed' : 'disabled');
    if (state.REMOUNT_DETAIL) {
      remountStr += `(${state.REMOUNT_DETAIL})`;
    }
    const gitStr = state.GIT_TUNING || (inputs.gitTuning ? 'failed' : 'disabled');
    let zramStr = state.ZRAM || (inputs.zram ? 'failed' : 'disabled');
    if (state.ZRAM_DEV && state.ZRAM === 'active') {
      zramStr += `(${state.ZRAM_DEV})`;
    }

    console.log(`⚡ make-github-action-fast: fsync-bypass=${fsyncStr} page-cache=${cacheStr} remount=${remountStr} git=${gitStr} zram=${zramStr} — setup ${setupMs} ms`);
  } catch (err) {
    const msg = err && err.message ? err.message : String(err);
    console.log(`::warning title=make-github-action-fast::Setup encountered an error: ${msg}`);
  }
}

if (require.main === module) {
  run();
}

module.exports = {
  T0,
  parseInputs,
  applyGitFallback,
  run,
};
