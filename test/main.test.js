'use strict';

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const { parseInputs, determineProfile } = require('../src/main');

describe('parseInputs', () => {
  test('returns default values when env is empty', () => {
    const inputs = parseInputs({});
    assert.equal(inputs.fsyncBypass, true);
    assert.equal(inputs.preloadScope, 'env');
    assert.equal(inputs.pageCacheTuning, true);
    assert.equal(inputs.remountFast, true);
    assert.equal(inputs.gitTuning, true);
    assert.equal(inputs.aptTuning, true);
    assert.equal(inputs.buildEnv, false);
    assert.equal(inputs.zramSwap, false);
    assert.equal(inputs.zramSwapSize, '50%');
    assert.equal(inputs.tmpfsPaths, '');
    assert.equal(inputs.tmpfsSize, '50%');
    assert.equal(inputs.selfHostedUnsafe, false);
    assert.equal(inputs.summary, true);
  });

  test('parses custom boolean and string inputs', () => {
    const env = {
      'INPUT_FSYNC-BYPASS': 'false',
      'INPUT_PRELOAD-SCOPE': 'global',
      'INPUT_PAGE-CACHE-TUNING': 'false',
      'INPUT_REMOUNT-FAST': 'false',
      'INPUT_GIT-TUNING': 'false',
      'INPUT_APT-TUNING': 'false',
      'INPUT_BUILD-ENV': 'true',
      'INPUT_ZRAM-SWAP': 'true',
      'INPUT_ZRAM-SWAP-SIZE': '4G',
      'INPUT_TMPFS-PATHS': '/tmp/cache',
      'INPUT_TMPFS-SIZE': '25%',
      'INPUT_SELF-HOSTED-UNSAFE': 'true',
      'INPUT_SUMMARY': 'false',
    };
    const inputs = parseInputs(env);
    assert.equal(inputs.fsyncBypass, false);
    assert.equal(inputs.preloadScope, 'global');
    assert.equal(inputs.pageCacheTuning, false);
    assert.equal(inputs.remountFast, false);
    assert.equal(inputs.gitTuning, false);
    assert.equal(inputs.aptTuning, false);
    assert.equal(inputs.buildEnv, true);
    assert.equal(inputs.zramSwap, true);
    assert.equal(inputs.zramSwapSize, '4G');
    assert.equal(inputs.tmpfsPaths, '/tmp/cache');
    assert.equal(inputs.tmpfsSize, '25%');
    assert.equal(inputs.selfHostedUnsafe, true);
    assert.equal(inputs.summary, false);
  });

  test('handles underscored input names', () => {
    const env = {
      INPUT_FSYNC_BYPASS: 'false',
      INPUT_ZRAM_SWAP: 'true',
      INPUT_ZRAM_SWAP_SIZE: '2G',
    };
    const inputs = parseInputs(env);
    assert.equal(inputs.fsyncBypass, false);
    assert.equal(inputs.zramSwap, true);
    assert.equal(inputs.zramSwapSize, '2G');
  });

  test('handles deprecated alias zram-workspace', () => {
    const env = {
      'INPUT_ZRAM-WORKSPACE': 'true',
    };
    const inputs = parseInputs(env);
    assert.equal(inputs.zramSwap, true);
  });

  test('handles deprecated alias zram-size', () => {
    const env = {
      'INPUT_ZRAM-SIZE': '8G',
    };
    const inputs = parseInputs(env);
    assert.equal(inputs.zramSwapSize, '8G');
  });

  test('handles deprecated alias spill-dirs without crash', () => {
    const env = {
      'INPUT_SPILL-DIRS': 'node_modules,target',
    };
    const inputs = parseInputs(env);
    assert.equal(typeof inputs, 'object');
  });
});

describe('determineProfile', () => {
  test('returns unprivileged when neither root nor sudo', () => {
    assert.equal(
      determineProfile({ isRoot: false, canSudo: false, runnerEnvironment: 'github-hosted', selfHostedUnsafe: false }),
      'unprivileged'
    );
  });

  test('returns hosted when root on github-hosted runner', () => {
    assert.equal(
      determineProfile({ isRoot: true, canSudo: false, runnerEnvironment: 'github-hosted', selfHostedUnsafe: false }),
      'hosted'
    );
  });

  test('returns hosted when canSudo on github-hosted runner', () => {
    assert.equal(
      determineProfile({ isRoot: false, canSudo: true, runnerEnvironment: 'github-hosted', selfHostedUnsafe: false }),
      'hosted'
    );
  });

  test('returns self-hosted-safe when privileged on self-hosted and unsafe is false', () => {
    assert.equal(
      determineProfile({ isRoot: true, canSudo: false, runnerEnvironment: 'self-hosted', selfHostedUnsafe: false }),
      'self-hosted-safe'
    );
  });

  test('returns self-hosted-unsafe when privileged on self-hosted and unsafe is true', () => {
    assert.equal(
      determineProfile({ isRoot: true, canSudo: false, runnerEnvironment: 'self-hosted', selfHostedUnsafe: true }),
      'self-hosted-unsafe'
    );
  });
});
