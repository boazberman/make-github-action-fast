'use strict';

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const {
  parseEnvFile,
  parseBool,
  sanitizeSize,
  validateTmpfsPaths,
  composeLdPreload,
  composeAsanOptions,
  composeGitConfigEnv,
  checkGitVersion,
  formatBytes,
  formatNumber,
  escapeMarkdown,
} = require('../src/common');

describe('parseEnvFile', () => {
  test('parses key=value lines', () => {
    const input = 'FOO=bar\nBAZ=123\n';
    assert.deepEqual(parseEnvFile(input), { FOO: 'bar', BAZ: '123' });
  });

  test('ignores comments and empty lines', () => {
    const input = '# Comment\n\nFOO=bar\n  # Indented comment\nBAZ=qux\n';
    assert.deepEqual(parseEnvFile(input), { FOO: 'bar', BAZ: 'qux' });
  });

  test('strips double and single quotes', () => {
    const input = 'A="hello world"\nB=\'single quotes\'\nC=unquoted\n';
    assert.deepEqual(parseEnvFile(input), {
      A: 'hello world',
      B: 'single quotes',
      C: 'unquoted',
    });
  });

  test('handles empty or non-string inputs', () => {
    assert.deepEqual(parseEnvFile(''), {});
    assert.deepEqual(parseEnvFile(null), {});
    assert.deepEqual(parseEnvFile(undefined), {});
  });
});

describe('parseBool', () => {
  test('parses truthy values', () => {
    assert.equal(parseBool('true'), true);
    assert.equal(parseBool('True'), true);
    assert.equal(parseBool('1'), true);
    assert.equal(parseBool('yes'), true);
    assert.equal(parseBool('on'), true);
    assert.equal(parseBool(true), true);
  });

  test('parses falsy values', () => {
    assert.equal(parseBool('false'), false);
    assert.equal(parseBool('FALSE'), false);
    assert.equal(parseBool('0'), false);
    assert.equal(parseBool('no'), false);
    assert.equal(parseBool('off'), false);
    assert.equal(parseBool(false), false);
  });

  test('falls back to default value', () => {
    assert.equal(parseBool('', true), true);
    assert.equal(parseBool('', false), false);
    assert.equal(parseBool(null, true), true);
    assert.equal(parseBool(undefined, false), false);
    assert.equal(parseBool('unknown', true), true);
    assert.equal(parseBool('unknown', false), false);
  });
});

describe('sanitizeSize', () => {
  test('accepts percentage values', () => {
    assert.equal(sanitizeSize('50%'), '50%');
    assert.equal(sanitizeSize(' 75% '), '75%');
  });

  test('accepts absolute unit sizes', () => {
    assert.equal(sanitizeSize('4G'), '4G');
    assert.equal(sanitizeSize('512m'), '512M');
    assert.equal(sanitizeSize('1024K'), '1024K');
    assert.equal(sanitizeSize('2T'), '2T');
    assert.equal(sanitizeSize('512MB'), '512MB');
  });

  test('falls back to default for invalid inputs', () => {
    assert.equal(sanitizeSize('invalid', '50%'), '50%');
    assert.equal(sanitizeSize('', '50%'), '50%');
    assert.equal(sanitizeSize(null, '6G'), '6G');
    assert.equal(sanitizeSize(';;rm -rf', '50%'), '50%');
  });
});

describe('validateTmpfsPaths', () => {
  const runnerHome = '/home/runner';
  const workspace = '/home/runner/work/my-repo/my-repo';

  test('accepts valid absolute paths outside workspace and root dirs', () => {
    const input = '/tmp/cache, /var/cache/build';
    const res = validateTmpfsPaths(input, runnerHome, workspace);
    assert.deepEqual(res.valid, ['/tmp/cache', '/var/cache/build']);
    assert.equal(res.rejected.length, 0);
  });

  test('expands leading ~/ to runnerHome', () => {
    const input = '~/.cache/cargo, ~/build-dir';
    const res = validateTmpfsPaths(input, runnerHome, workspace);
    assert.deepEqual(res.valid, ['/home/runner/.cache/cargo', '/home/runner/build-dir']);
    assert.equal(res.rejected.length, 0);
  });

  test('rejects relative paths', () => {
    const input = 'relative/path, ./local';
    const res = validateTmpfsPaths(input, runnerHome, workspace);
    assert.equal(res.valid.length, 0);
    assert.equal(res.rejected.length, 2);
    assert.match(res.rejected[0].reason, /relative/i);
  });

  test('rejects system directories', () => {
    const input = '/, /proc, /sys, /dev, /run, /boot, /etc, /usr, /var/lib/docker';
    const res = validateTmpfsPaths(input, runnerHome, workspace);
    assert.equal(res.valid.length, 0);
    assert.equal(res.rejected.length, 9);
    for (const r of res.rejected) {
      assert.match(r.reason, /rejected/i);
    }
  });

  test('rejects $HOME itself', () => {
    const input = '~, /home/runner, ~/subdir';
    const res = validateTmpfsPaths(input, runnerHome, workspace);
    assert.deepEqual(res.valid, ['/home/runner/subdir']);
    assert.equal(res.rejected.length, 2);
  });

  test('rejects paths under GITHUB_WORKSPACE', () => {
    const input = `${workspace}, ${workspace}/node_modules, /var/cache`;
    const res = validateTmpfsPaths(input, runnerHome, workspace);
    assert.deepEqual(res.valid, ['/var/cache']);
    assert.equal(res.rejected.length, 2);
    assert.match(res.rejected[0].reason, /GITHUB_WORKSPACE/i);
  });

  test('deduplicates paths', () => {
    const input = '/var/cache/foo, /var/cache/foo, /var/cache/foo/';
    const res = validateTmpfsPaths(input, runnerHome, workspace);
    assert.deepEqual(res.valid, ['/var/cache/foo']);
  });
});

describe('composeLdPreload', () => {
  test('returns newLib when existing is empty', () => {
    assert.equal(composeLdPreload('', '/usr/lib/libnosync.so'), '/usr/lib/libnosync.so');
    assert.equal(composeLdPreload(undefined, 'libnosync.so'), 'libnosync.so');
  });

  test('prepends newLib to existing', () => {
    assert.equal(
      composeLdPreload('/usr/lib/libother.so', '/usr/lib/libnosync.so'),
      '/usr/lib/libnosync.so:/usr/lib/libother.so'
    );
  });

  test('deduplicates by basename', () => {
    const existing = '/old/path/libnosync.so:/usr/lib/libother.so';
    assert.equal(
      composeLdPreload(existing, '/usr/lib/libnosync.so'),
      '/usr/lib/libnosync.so:/usr/lib/libother.so'
    );
  });

  test('returns existing if newLib is empty', () => {
    assert.equal(composeLdPreload('/usr/lib/libother.so', ''), '/usr/lib/libother.so');
  });
});

describe('composeAsanOptions', () => {
  test('sets option when existing is empty', () => {
    assert.equal(composeAsanOptions(''), 'verify_asan_link_order=0');
    assert.equal(composeAsanOptions(undefined), 'verify_asan_link_order=0');
  });

  test('appends option with colon if not present', () => {
    assert.equal(composeAsanOptions('detect_leaks=0'), 'detect_leaks=0:verify_asan_link_order=0');
  });

  test('does not duplicate if already present', () => {
    assert.equal(composeAsanOptions('verify_asan_link_order=0'), 'verify_asan_link_order=0');
    assert.equal(
      composeAsanOptions('detect_leaks=0:verify_asan_link_order=0'),
      'detect_leaks=0:verify_asan_link_order=0'
    );
  });
});

describe('composeGitConfigEnv', () => {
  const configs = [
    ['gc.auto', '0'],
    ['checkout.workers', '0'],
  ];

  test('starts at index 0 when GIT_CONFIG_COUNT is unset', () => {
    const res = composeGitConfigEnv({}, configs);
    assert.deepEqual(res, {
      GIT_CONFIG_KEY_0: 'gc.auto',
      GIT_CONFIG_VALUE_0: '0',
      GIT_CONFIG_KEY_1: 'checkout.workers',
      GIT_CONFIG_VALUE_1: '0',
      GIT_CONFIG_COUNT: '2',
    });
  });

  test('appends starting at existing GIT_CONFIG_COUNT', () => {
    const res = composeGitConfigEnv({ GIT_CONFIG_COUNT: '2' }, configs);
    assert.deepEqual(res, {
      GIT_CONFIG_KEY_2: 'gc.auto',
      GIT_CONFIG_VALUE_2: '0',
      GIT_CONFIG_KEY_3: 'checkout.workers',
      GIT_CONFIG_VALUE_3: '0',
      GIT_CONFIG_COUNT: '4',
    });
  });
});

describe('checkGitVersion', () => {
  test('returns true for git >= 2.31.0', () => {
    assert.equal(checkGitVersion('git version 2.31.0'), true);
    assert.equal(checkGitVersion('git version 2.34.1'), true);
    assert.equal(checkGitVersion('git version 2.43.0.windows.1'), true);
    assert.equal(checkGitVersion('git version 3.0.0'), true);
  });

  test('returns false for git < 2.31.0 or invalid', () => {
    assert.equal(checkGitVersion('git version 2.30.9'), false);
    assert.equal(checkGitVersion('git version 2.25.1'), false);
    assert.equal(checkGitVersion('git version 1.8.3'), false);
    assert.equal(checkGitVersion(''), false);
    assert.equal(checkGitVersion(null), false);
    assert.equal(checkGitVersion('command not found'), false);
  });
});

describe('formatting utilities', () => {
  test('formatBytes formats units accurately', () => {
    assert.equal(formatBytes(0), '0 B');
    assert.equal(formatBytes(500), '500 B');
    assert.equal(formatBytes(1024), '1.0 KiB');
    assert.equal(formatBytes(1024 * 1024 * 5), '5.0 MiB');
    assert.equal(formatBytes(1024 * 1024 * 1024 * 2.5), '2.5 GiB');
  });

  test('formatNumber adds commas', () => {
    assert.equal(formatNumber(0), '0');
    assert.equal(formatNumber(100), '100');
    assert.equal(formatNumber(1000), '1,000');
    assert.equal(formatNumber(1234567), '1,234,567');
  });

  test('escapeMarkdown escapes pipes and removes newlines', () => {
    assert.equal(escapeMarkdown('hello | world'), 'hello \\| world');
    assert.equal(escapeMarkdown('multi\nline\r\nstring'), 'multi line string');
    assert.equal(escapeMarkdown(null), '');
  });
});
