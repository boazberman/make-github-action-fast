'use strict';

// Captured before any require() so the reported setup time includes module loading.
const T0 = Date.now();

const fs = require('fs');
const os = require('os');
const path = require('path');
const child_process = require('child_process');
const {
  parseEnvFile,
  parseBool,
  sanitizeSize,
  validateTmpfsPaths,
  composeLdPreload,
  composeAsanOptions,
  composeGitConfigEnv,
  checkGitVersion,
  safeReadFile,
  appendGithubFile,
  appendGithubEnv,
  appendGithubOutput,
  appendGithubState,
  runRootScript,
} = require('./common');

/**
 * Parse inputs from environment variables, including deprecated aliases.
 *
 * @param {Record<string, string|undefined>} [env]
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
  const preloadScopeRaw = get('preload-scope', 'env').toLowerCase();
  const preloadScope = preloadScopeRaw === 'global' ? 'global' : 'env';
  const pageCacheTuning = parseBool(get('page-cache-tuning', 'true'), true);
  const remountFast = parseBool(get('remount-fast', 'true'), true);
  const gitTuning = parseBool(get('git-tuning', 'true'), true);
  const aptTuning = parseBool(get('apt-tuning', 'true'), true);
  const buildEnv = parseBool(get('build-env', 'false'), false);

  let zramSwap = parseBool(get('zram-swap', 'false'), false);
  let zramSwapSize = sanitizeSize(get('zram-swap-size', '50%'), '50%');

  // Deprecated zram-workspace alias
  const rawZramWorkspace = get('zram-workspace', '');
  if (rawZramWorkspace !== '') {
    console.log("::warning title=overclock::Input 'zram-workspace' is deprecated; use 'zram-swap' instead.");
    if (parseBool(rawZramWorkspace, false)) {
      zramSwap = true;
    }
  }

  // Deprecated zram-size alias
  const rawZramSize = get('zram-size', '');
  if (rawZramSize !== '') {
    console.log("::warning title=overclock::Input 'zram-size' is deprecated; use 'zram-swap-size' instead.");
    if (zramSwapSize === '50%') {
      zramSwapSize = sanitizeSize(rawZramSize, '50%');
    }
  }

  // Deprecated spill-dirs alias
  const rawSpillDirs = get('spill-dirs', '');
  if (rawSpillDirs !== '') {
    console.log("::warning title=overclock::Input 'spill-dirs' is deprecated and ignored.");
  }

  const tmpfsPaths = get('tmpfs-paths', '');
  const tmpfsSize = sanitizeSize(get('tmpfs-size', '50%'), '50%');
  const selfHostedUnsafe = parseBool(get('self-hosted-unsafe', 'false'), false);
  const summary = parseBool(get('summary', 'true'), true);

  return {
    fsyncBypass,
    preloadScope,
    pageCacheTuning,
    remountFast,
    gitTuning,
    aptTuning,
    buildEnv,
    zramSwap,
    zramSwapSize,
    tmpfsPaths,
    tmpfsSize,
    selfHostedUnsafe,
    summary,
  };
}

/**
 * Determine privilege profile.
 *
 * @param {object} params
 * @param {boolean} params.isRoot
 * @param {boolean} params.canSudo
 * @param {string} [params.runnerEnvironment]
 * @param {boolean} [params.selfHostedUnsafe]
 * @returns {'hosted'|'self-hosted-safe'|'self-hosted-unsafe'|'unprivileged'}
 */
function determineProfile({ isRoot, canSudo, runnerEnvironment, selfHostedUnsafe }) {
  const isPrivileged = Boolean(isRoot || canSudo);
  if (!isPrivileged) {
    return 'unprivileged';
  }
  if (runnerEnvironment === 'self-hosted') {
    return selfHostedUnsafe ? 'self-hosted-unsafe' : 'self-hosted-safe';
  }
  return 'hosted';
}

/**
 * Main action execution function.
 */
function run() {
  try {
    if (process.platform !== 'linux') {
      console.log(`::notice title=overclock::Unsupported platform ${process.platform}; skipping (Linux runners only).`);
      return;
    }

    const inputs = parseInputs(process.env);
    const actionPath = path.resolve(__dirname, '..');
    const runnerHome = process.env.HOME || (typeof os.homedir === 'function' ? os.homedir() : '');
    const workspace = process.env.GITHUB_WORKSPACE || process.cwd();

    // Determine privilege and profile
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

    const profile = determineProfile({
      isRoot,
      canSudo,
      runnerEnvironment: process.env.RUNNER_ENVIRONMENT,
      selfHostedUnsafe: inputs.selfHostedUnsafe,
    });

    // State directory: $RUNNER_TEMP/overclock fallback os.tmpdir()/overclock-<pid>
    const stateDir = process.env.RUNNER_TEMP
      ? path.join(process.env.RUNNER_TEMP, 'overclock')
      : path.join(os.tmpdir(), `overclock-${process.pid}`);

    try {
      fs.mkdirSync(stateDir, { recursive: true });
      fs.mkdirSync(path.join(stateDir, 'lib'), { recursive: true });
    } catch {}

    const stateFile = path.join(stateDir, 'state.env');
    const metricsFile = path.join(stateDir, 'metrics-start.env');
    const statsFile = path.join(stateDir, 'nosync-stats');
    const setupLog = path.join(stateDir, 'setup.log');

    // Create empty stats file
    try {
      if (!fs.existsSync(statsFile)) {
        fs.writeFileSync(statsFile, '', { mode: 0o666 });
      }
    } catch {}

    let uid = 1000;
    let gid = 1000;
    try {
      const info = os.userInfo();
      if (typeof info.uid === 'number') uid = info.uid;
      if (typeof info.gid === 'number') gid = info.gid;
    } catch {}

    // Validate tmpfs paths
    const { valid: validTmpfs, rejected: rejectedTmpfs } = validateTmpfsPaths(
      inputs.tmpfsPaths,
      runnerHome,
      workspace
    );
    for (const r of rejectedTmpfs) {
      console.log(`::warning title=overclock::tmpfs path rejected: ${r.path} (${r.reason})`);
    }

    // Git tuning via GITHUB_ENV
    let gitStatus = 'disabled';
    if (inputs.gitTuning) {
      let gitSupported = false;
      try {
        const vOut = child_process.execFileSync('git', ['--version'], {
          encoding: 'utf8',
          timeout: 5000,
          stdio: ['ignore', 'pipe', 'ignore'],
        });
        gitSupported = checkGitVersion(vOut);
      } catch {
        gitSupported = false;
      }

      if (gitSupported) {
        const gitConfigs = [
          ['gc.auto', '0'],
          ['maintenance.auto', 'false'],
          ['checkout.workers', '0'],
          ['fetch.parallel', '0'],
          ['submodule.fetchJobs', '0'],
          ['core.untrackedCache', 'true'],
        ];
        const envKvs = composeGitConfigEnv(process.env, gitConfigs);
        for (const [k, v] of Object.entries(envKvs)) {
          appendGithubEnv(k, v);
          process.env[k] = v;
        }
        gitStatus = 'env';
      } else {
        gitStatus = 'skipped';
      }
    }

    // Build env tuning
    let buildEnvStatus = 'disabled';
    if (inputs.buildEnv) {
      const cpuCount = (os.cpus() && os.cpus().length) || 2;
      if (!process.env.MAKEFLAGS) {
        appendGithubEnv('MAKEFLAGS', `-j${cpuCount}`);
      }
      if (!process.env.CMAKE_BUILD_PARALLEL_LEVEL) {
        appendGithubEnv('CMAKE_BUILD_PARALLEL_LEVEL', String(cpuCount));
      }
      if (!process.env.CARGO_INCREMENTAL) {
        appendGithubEnv('CARGO_INCREMENTAL', '0');
      }
      if (!process.env.CARGO_NET_GIT_FETCH_WITH_CLI) {
        appendGithubEnv('CARGO_NET_GIT_FETCH_WITH_CLI', 'true');
      }
      if (!process.env.MALLOC_ARENA_MAX) {
        appendGithubEnv('MALLOC_ARENA_MAX', String(cpuCount));
      }
      buildEnvStatus = 'active';
    }

    // Run setup-linux.sh
    const scriptEnv = {
      OVERCLOCK_ACTION_PATH: actionPath,
      OVERCLOCK_PROFILE: profile,
      OVERCLOCK_STATE_DIR: stateDir,
      OVERCLOCK_FSYNC_BYPASS: String(inputs.fsyncBypass),
      OVERCLOCK_PRELOAD_SCOPE: inputs.preloadScope,
      OVERCLOCK_PAGE_CACHE: String(inputs.pageCacheTuning),
      OVERCLOCK_REMOUNT: String(inputs.remountFast),
      OVERCLOCK_APT_TUNING: String(inputs.aptTuning),
      OVERCLOCK_ZRAM_SWAP: String(inputs.zramSwap),
      OVERCLOCK_ZRAM_SWAP_SIZE: inputs.zramSwapSize,
      OVERCLOCK_TMPFS_PATHS: validTmpfs.join(','),
      OVERCLOCK_TMPFS_SIZE: inputs.tmpfsSize,
      OVERCLOCK_SELF_HOSTED_UNSAFE: String(inputs.selfHostedUnsafe),
      OVERCLOCK_WORKSPACE: workspace,
      OVERCLOCK_UID: String(uid),
      OVERCLOCK_GID: String(gid),
      OVERCLOCK_START_EPOCH_MS: String(T0),
    };

    console.log('::group::overclock setup');
    const setupScript = path.join(actionPath, 'src', 'setup-linux.sh');
    const scriptResult = runRootScript(setupScript, ['setup'], scriptEnv, { timeout: 60000 });
    console.log('::endgroup::');

    if (scriptResult.error) {
      console.log(`::warning title=overclock::setup-linux.sh error: ${scriptResult.error.message}`);
    } else if (scriptResult.status !== 0) {
      console.log(`::warning title=overclock::setup-linux.sh exited with code ${scriptResult.status}`);
    }

    // When RUNNER_DEBUG=1, print setup.log
    if (process.env.RUNNER_DEBUG === '1' || process.env.ACTIONS_STEP_DEBUG === 'true') {
      const logContent = safeReadFile(setupLog);
      if (logContent && logContent.trim()) {
        console.log('::group::overclock setup log');
        console.log(logContent.trim());
        console.log('::endgroup::');
      }
    }

    // Read state file
    const rawState = safeReadFile(stateFile);
    const state = parseEnvFile(rawState || '');

    // Record git and build env statuses into state
    state.GIT_TUNING = gitStatus;
    state.BUILD_ENV = buildEnvStatus;
    state.PROFILE = profile;
    appendGithubFile(stateFile, 'GIT_TUNING', gitStatus);
    appendGithubFile(stateFile, 'BUILD_ENV', buildEnvStatus);
    appendGithubFile(stateFile, 'PROFILE', profile);

    // LD_PRELOAD, ASAN_OPTIONS, and NOSYNC_STATS_FILE injection
    if (state.FSYNC_BYPASS === 'active' && state.LD_PRELOAD_VALUE) {
      const preloadVal = composeLdPreload(process.env.LD_PRELOAD, state.LD_PRELOAD_VALUE);
      appendGithubEnv('LD_PRELOAD', preloadVal);
      appendGithubEnv('NOSYNC_ACTIVE', '1');

      const asanVal = composeAsanOptions(process.env.ASAN_OPTIONS);
      appendGithubEnv('ASAN_OPTIONS', asanVal);

      appendGithubEnv('NOSYNC_STATS_FILE', statsFile);
    }

    // Save action state for post hook
    appendGithubState('start_ms', String(T0));
    appendGithubState('state_dir', stateDir);
    appendGithubState('summary', inputs.summary ? 'true' : 'false');
    appendGithubState('profile', profile);
    appendGithubState('privileged', profile !== 'unprivileged' ? 'true' : 'false');

    // Outputs
    const setupMs = Date.now() - T0;
    appendGithubOutput('setup-time-ms', String(setupMs));
    appendGithubOutput('fsync-bypass', state.FSYNC_BYPASS || (inputs.fsyncBypass ? 'failed' : 'disabled'));
    appendGithubOutput('zram-device', state.ZRAM_DEV || '');
    appendGithubOutput('profile', profile);

    // One-line summary
    const fsyncStr = state.FSYNC_BYPASS || (inputs.fsyncBypass ? 'failed' : 'disabled');
    const cacheStr = state.PAGE_CACHE || (inputs.pageCacheTuning ? 'failed' : 'disabled');
    const remountStr = state.REMOUNT || (inputs.remountFast ? 'failed' : 'disabled');
    const aptStr = state.APT_TUNING || (inputs.aptTuning ? 'failed' : 'disabled');
    let zramStr = state.ZRAM_SWAP || (inputs.zramSwap ? 'failed' : 'disabled');
    if (state.ZRAM_DEV && state.ZRAM_SWAP === 'active') {
      zramStr += `(${state.ZRAM_DEV})`;
    }
    const tmpfsStr = state.TMPFS_PATHS || (inputs.tmpfsPaths ? 'failed' : 'disabled');

    console.log(
      `⚡ overclock: profile=${profile} fsync-bypass=${fsyncStr} page-cache=${cacheStr} remount=${remountStr} git=${gitStatus} apt=${aptStr} zram=${zramStr} tmpfs=${tmpfsStr} — setup ${setupMs} ms`
    );
  } catch (err) {
    const msg = err && err.message ? err.message : String(err);
    console.log(`::warning title=overclock::Setup encountered an error: ${msg}`);
  }
}

if (require.main === module) {
  run();
}

module.exports = {
  T0,
  parseInputs,
  determineProfile,
  run,
};
