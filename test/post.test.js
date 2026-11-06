'use strict';

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const {
  parseNosyncStats,
  parseCpuStat,
  computeCpuDelta,
  parseMeminfo,
  parseVmstat,
  parseDiskstats,
  parseMountinfo,
  parseZramctl,
  parseMmStat,
  statusEmoji,
  computeTelemetryData,
  generateMarkdown,
  generatePlainTextSummary,
} = require('../src/post');

describe('parseNosyncStats', () => {
  test('parses single process stats', () => {
    const content = '1234 200 5\n';
    const res = parseNosyncStats(content);
    assert.deepEqual(res, {
      skippedSync: 200,
      strippedOsync: 5,
      processes: 1,
    });
  });

  test('sums across multiple process lines', () => {
    const content = '1001 50 2\n1002 150 0\n1003 0 10\n';
    const res = parseNosyncStats(content);
    assert.deepEqual(res, {
      skippedSync: 200,
      strippedOsync: 12,
      processes: 3,
    });
  });

  test('ignores processes with 0 0', () => {
    const content = '1001 0 0\n1002 10 1\n';
    const res = parseNosyncStats(content);
    assert.deepEqual(res, {
      skippedSync: 10,
      strippedOsync: 1,
      processes: 1,
    });
  });

  test('tolerates garbage lines and comments', () => {
    const content = '# Comment\ninvalid line\n1001 10\n1002 40 4 extra tokens\n\n';
    const res = parseNosyncStats(content);
    assert.deepEqual(res, {
      skippedSync: 40,
      strippedOsync: 4,
      processes: 1,
    });
  });

  test('handles empty or non-string input', () => {
    assert.deepEqual(parseNosyncStats(''), { skippedSync: 0, strippedOsync: 0, processes: 0 });
    assert.deepEqual(parseNosyncStats(null), { skippedSync: 0, strippedOsync: 0, processes: 0 });
    assert.deepEqual(parseNosyncStats(undefined), { skippedSync: 0, strippedOsync: 0, processes: 0 });
  });
});

describe('parseCpuStat', () => {
  test('parses cpu line from /proc/stat', () => {
    const sample = 'cpu  100 20 30 400 50 6 7 8 0 0\ncpu0 50 10 15 200 ...\n';
    const parsed = parseCpuStat(sample);
    assert.ok(parsed);
    assert.deepEqual(parsed.numbers, [100, 20, 30, 400, 50, 6, 7, 8]);
    assert.equal(parsed.total, 621);
  });

  test('returns null for missing or invalid content', () => {
    assert.equal(parseCpuStat(''), null);
    assert.equal(parseCpuStat('invalid cpu stat line'), null);
  });
});

describe('computeCpuDelta', () => {
  test('computes iowait and user+sys percentage', () => {
    const base = [100, 0, 50, 1000, 20, 0, 0, 0];
    const cur = {
      numbers: [150, 0, 70, 1050, 40, 0, 0, 0],
      total: 1310,
    };
    // deltas: user=50, sys=20, idle=50, iowait=20. deltaTotal = 140.
    // iowaitPct = 20 / 140 * 100 = 14.3%
    // userSysPct = (50 + 20) / 140 * 100 = 50.0%
    const res = computeCpuDelta(base, cur);
    assert.equal(res.iowaitPct, '14.3%');
    assert.equal(res.userSysPct, '50.0%');
  });

  test('handles zero delta gracefully', () => {
    const base = [100, 0, 0, 100, 0, 0, 0, 0];
    const cur = [100, 0, 0, 100, 0, 0, 0, 0];
    const res = computeCpuDelta(base, cur);
    assert.equal(res.iowaitPct, '0.0%');
    assert.equal(res.userSysPct, '0.0%');
  });
});

describe('parseMeminfo', () => {
  test('parses fields and converts kB to bytes', () => {
    const sample = `
MemTotal:       16384000 kB
MemAvailable:    8192000 kB
Cached:          4096000 kB
Dirty:            102400 kB
Writeback:          1024 kB
SwapTotal:       2048000 kB
SwapFree:        1024000 kB
`;
    const mem = parseMeminfo(sample);
    assert.equal(mem.memTotal, 16384000 * 1024);
    assert.equal(mem.memAvailable, 8192000 * 1024);
    assert.equal(mem.cached, 4096000 * 1024);
    assert.equal(mem.dirty, 102400 * 1024);
    assert.equal(mem.writeback, 1024 * 1024);
    assert.equal(mem.swapTotal, 2048000 * 1024);
    assert.equal(mem.swapFree, 1024000 * 1024);
    assert.equal(mem.swapUsed, (2048000 - 1024000) * 1024);
  });
});

describe('parseVmstat', () => {
  test('parses vmstat key-value lines', () => {
    const sample = 'nr_dirtied 12345\npswpout 678\noom_kill 0\n';
    const vm = parseVmstat(sample);
    assert.equal(vm.nr_dirtied, 12345);
    assert.equal(vm.pswpout, 678);
    assert.equal(vm.oom_kill, 0);
  });
});

describe('parseDiskstats', () => {
  test('aggregates non-pseudo disk statistics', () => {
    const sample = `
   8       0 sda 100 0 2000 10 500 0 8000 50 0 100 200 0 0 0
   8      16 sdb 200 0 4000 20 600 0 9000 60 0 150 250 0 0 0
   7       0 loop0 10 0 20 1 0 0 0 0 0 0 0 0 0 0
`;
    const stats = parseDiskstats(sample);
    assert.equal(stats.devices.length, 2);
    assert.equal(stats.rdIos, 300);
    assert.equal(stats.rdSectors, 6000);
    assert.equal(stats.wrIos, 1100);
    assert.equal(stats.wrSectors, 17000);
    assert.equal(stats.ioTicks, 250);
  });
});

describe('parseMountinfo', () => {
  test('extracts mountpoints decoding octal escapes', () => {
    const sample = `
36 35 0:31 / /tmp rw,nosuid,nodev - tmpfs tmpfs rw
37 35 0:32 / /home/runner/work\\040space rw - ext4 /dev/sda1 rw
`;
    const mps = parseMountinfo(sample);
    assert.ok(mps.has('/tmp'));
    assert.ok(mps.has('/home/runner/work space'));
  });
});

describe('parseZramctl and parseMmStat', () => {
  test('parseZramctl parses raw fields', () => {
    const sample = '/dev/zram0 lz4 4294967296 104857600 26214400 30000000\n';
    const parsed = parseZramctl(sample);
    assert.ok(parsed);
    assert.equal(parsed.dev, '/dev/zram0');
    assert.equal(parsed.algorithm, 'lz4');
    assert.equal(parsed.diskSize, 4294967296);
    assert.equal(parsed.data, 104857600);
    assert.equal(parsed.compr, 26214400);
    assert.equal(parsed.ratio, '4.00');
  });

  test('parseMmStat parses /sys/block/zramX/mm_stat', () => {
    const sample = '  104857600   26214400   30000000          0   30000000        0        0\n';
    const parsed = parseMmStat(sample);
    assert.ok(parsed);
    assert.equal(parsed.origSize, 104857600);
    assert.equal(parsed.comprSize, 26214400);
    assert.equal(parsed.ratio, '4.00');
  });
});

describe('statusEmoji', () => {
  test('maps status strings to emojis', () => {
    assert.match(statusEmoji('active'), /✅/);
    assert.match(statusEmoji('env'), /✅/);
    assert.match(statusEmoji('global'), /✅/);
    assert.match(statusEmoji('partial'), /⚠️/);
    assert.match(statusEmoji('failed'), /❌/);
    assert.match(statusEmoji('disabled'), /➖/);
    assert.match(statusEmoji('skipped'), /⏭️/);
  });
});

describe('computeTelemetryData and generateMarkdown', () => {
  test('computes full telemetry object and generates valid markdown', () => {
    const baseline = {
      START_EPOCH_MS: String(Date.now() - 5000),
      CPU_STAT: '100 0 20 500 10 0 0 0',
      VMSTAT_nr_dirtied: '1000',
      VMSTAT_pswpout: '0',
      VMSTAT_oom_kill: '0',
      DISK_READ_IOS: '50',
      DISK_READ_SECTORS: '1000',
      DISK_WRITE_IOS: '100',
      DISK_WRITE_SECTORS: '2000',
      DISK_IO_TICKS_MS: '200',
      DISK_DEVICES: 'sda',
    };

    const state = {
      PROFILE: 'hosted',
      FSYNC_BYPASS: 'active',
      LD_PRELOAD_VALUE: 'libnosync.so',
      FSYNC_COMPILE_MS: '25',
      PAGE_CACHE: 'active',
      REMOUNT: 'active',
      GIT_TUNING: 'env',
      APT_TUNING: 'active',
      BUILD_ENV: 'active',
      ZRAM_SWAP: 'active',
      ZRAM_DEV: '/dev/zram0',
      ZRAM_SIZE: '4G',
      ZRAM_ALGO: 'lz4',
      TMPFS_PATHS: 'active',
      TMPFS_MOUNTED: '/tmp/cache',
      SETUP_SCRIPT_MS: '120',
    };

    const nosyncStats = {
      skippedSync: 250,
      strippedOsync: 8,
      processes: 5,
    };

    const currentCpuStat = 'cpu  150 0 35 600 20 0 0 0 0 0';
    const currentMeminfoStr = `
MemTotal:       16384000 kB
MemAvailable:    8192000 kB
Cached:          4096000 kB
Dirty:            102400 kB
Writeback:          1024 kB
SwapTotal:       4194304 kB
SwapFree:        4194304 kB
`;
    const currentVmstatStr = 'nr_dirtied 2500\npswpout 0\noom_kill 0\n';
    const currentDiskstatsStr = '   8       0 sda 70 0 1400 15 150 0 3000 40 0 50 350 0 0 0\n';

    const zramOverride = {
      dev: '/dev/zram0',
      algorithm: 'lz4',
      diskSize: '4.0 GiB',
      data: '200.0 MiB',
      compr: '50.0 MiB',
      total: '55.0 MiB',
      ratio: '4.00:1',
    };

    const telemetryData = computeTelemetryData({
      baseline,
      state,
      nosyncStats,
      currentCpuStat,
      currentMeminfoStr,
      currentVmstatStr,
      currentDiskstatsStr,
      zramInfoOverride: zramOverride,
    });

    assert.ok(telemetryData.optimizations.length >= 8);
    assert.equal(telemetryData.nosyncImpact.skippedSync, 250);
    assert.equal(telemetryData.nosyncImpact.strippedOsync, 8);
    assert.equal(telemetryData.nosyncImpact.processes, 5);

    // Markdown verification
    const md = generateMarkdown(telemetryData);
    assert.match(md, /## ⚡ overclock/);
    assert.match(md, /### Optimizations/);
    assert.match(md, /### fsync Bypass Impact/);
    assert.match(md, /Sync calls skipped/);
    assert.match(md, /250/);
    assert.match(md, /### System I\/O Telemetry/);
    assert.match(md, /### zram Swap/);
    assert.match(md, /\/dev\/zram0/);

    // Plain text summary verification
    const plain = generatePlainTextSummary(telemetryData);
    assert.match(plain, /⚡ overclock telemetry summary:/);
    assert.match(plain, /fsync impact: skipped 250 sync calls/);
  });
});
