'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const child_process = require('child_process');
const {
  parseEnvFile,
  parseBool,
  escapeMarkdown,
  formatBytes,
  formatNumber,
  safeReadFile,
  appendGithubSummary,
  runRootScript,
} = require('./common');

/**
 * Parse NOSYNC_STATS_FILE content.
 * Tolerates garbage and malformed lines.
 *
 * @param {string} content
 * @returns {{ skippedSync: number, strippedOsync: number, processes: number }}
 */
function parseNosyncStats(content) {
  const result = {
    skippedSync: 0,
    strippedOsync: 0,
    processes: 0,
  };
  if (!content || typeof content !== 'string') {
    return result;
  }

  const lines = content.split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) {
      continue;
    }
    const parts = line.split(/\s+/);
    if (parts.length >= 3) {
      const skipped = parseInt(parts[1], 10);
      const stripped = parseInt(parts[2], 10);
      if (!isNaN(skipped) && !isNaN(stripped) && (skipped > 0 || stripped > 0)) {
        result.skippedSync += Math.max(0, skipped);
        result.strippedOsync += Math.max(0, stripped);
        result.processes += 1;
      }
    }
  }

  return result;
}

/**
 * Parse CPU stats from /proc/stat content.
 * Returns array of [user, nice, system, idle, iowait, irq, softirq, steal]
 * and sum total (first 8 fields, excluding guest).
 *
 * @param {string} content
 * @returns {{ numbers: number[], total: number }|null}
 */
function parseCpuStat(content) {
  if (!content || typeof content !== 'string') return null;
  const match = content.match(/^cpu\s+([0-9\s]+)/m);
  if (!match) return null;
  const numbers = match[1].trim().split(/\s+/).slice(0, 8).map(Number);
  if (numbers.length < 8) return null;
  const total = numbers.reduce((acc, n) => acc + n, 0);
  return { numbers, total };
}

/**
 * Compute CPU usage percentages between baseline and current /proc/stat.
 *
 * @param {string|number[]} baselineCpu - string of space-separated numbers or array
 * @param {string|{ numbers: number[], total: number }} currentCpu
 * @returns {{ iowaitPct: string, userSysPct: string, deltaIowait: number, deltaTotal: number }}
 */
function computeCpuDelta(baselineCpu, currentCpu) {
  let baseNums = [];
  if (Array.isArray(baselineCpu)) {
    baseNums = baselineCpu;
  } else if (typeof baselineCpu === 'string') {
    baseNums = baselineCpu.trim().split(/\s+/).slice(0, 8).map(Number);
  }

  let curNums = [];
  if (currentCpu && currentCpu.numbers) {
    curNums = currentCpu.numbers;
  } else if (typeof currentCpu === 'string') {
    const parsed = parseCpuStat(currentCpu);
    if (parsed) curNums = parsed.numbers;
  }

  if (baseNums.length < 8 || curNums.length < 8) {
    return { iowaitPct: '0.0%', userSysPct: '0.0%', deltaIowait: 0, deltaTotal: 0 };
  }

  const deltaUser = Math.max(0, curNums[0] - baseNums[0]);
  const deltaNice = Math.max(0, curNums[1] - baseNums[1]);
  const deltaSys = Math.max(0, curNums[2] - baseNums[2]);
  const deltaIdle = Math.max(0, curNums[3] - baseNums[3]);
  const deltaIowait = Math.max(0, curNums[4] - baseNums[4]);
  const deltaIrq = Math.max(0, curNums[5] - baseNums[5]);
  const deltaSoftirq = Math.max(0, curNums[6] - baseNums[6]);
  const deltaSteal = Math.max(0, curNums[7] - baseNums[7]);

  const deltaTotal = deltaUser + deltaNice + deltaSys + deltaIdle + deltaIowait + deltaIrq + deltaSoftirq + deltaSteal;

  if (deltaTotal <= 0) {
    return { iowaitPct: '0.0%', userSysPct: '0.0%', deltaIowait: 0, deltaTotal: 0 };
  }

  const iowaitPct = ((deltaIowait / deltaTotal) * 100).toFixed(1) + '%';
  const userSysPct = (((deltaUser + deltaSys) / deltaTotal) * 100).toFixed(1) + '%';

  return { iowaitPct, userSysPct, deltaIowait, deltaTotal };
}

/**
 * Parse /proc/meminfo lines into key-value map in bytes.
 *
 * @param {string} content
 * @returns {Record<string, number>}
 */
function parseMeminfo(content) {
  const result = {
    memTotal: 0,
    memAvailable: 0,
    cached: 0,
    dirty: 0,
    writeback: 0,
    swapTotal: 0,
    swapFree: 0,
    swapUsed: 0,
  };
  if (!content || typeof content !== 'string') return result;

  const lines = content.split(/\r?\n/);
  for (const line of lines) {
    const parts = line.split(':');
    if (parts.length < 2) continue;
    const key = parts[0].trim();
    const valKb = parseInt(parts[1].trim(), 10);
    if (isNaN(valKb)) continue;

    const valBytes = valKb * 1024;
    switch (key) {
      case 'MemTotal':
        result.memTotal = valBytes;
        break;
      case 'MemAvailable':
        result.memAvailable = valBytes;
        break;
      case 'Cached':
        result.cached = valBytes;
        break;
      case 'Dirty':
        result.dirty = valBytes;
        break;
      case 'Writeback':
        result.writeback = valBytes;
        break;
      case 'SwapTotal':
        result.swapTotal = valBytes;
        break;
      case 'SwapFree':
        result.swapFree = valBytes;
        break;
    }
  }

  result.swapUsed = Math.max(0, result.swapTotal - result.swapFree);
  return result;
}

/**
 * Parse /proc/vmstat lines into key-value map.
 *
 * @param {string} content
 * @returns {Record<string, number>}
 */
function parseVmstat(content) {
  const result = {};
  if (!content || typeof content !== 'string') return result;

  const lines = content.split(/\r?\n/);
  for (const line of lines) {
    const parts = line.trim().split(/\s+/);
    if (parts.length >= 2) {
      const val = parseInt(parts[1], 10);
      if (!isNaN(val)) {
        result[parts[0]] = val;
      }
    }
  }
  return result;
}

/**
 * Parse /proc/diskstats and aggregate metrics for target devices.
 *
 * @param {string} content
 * @param {string[]|string} [targetDevices]
 * @returns {{ rdIos: number, rdSectors: number, wrIos: number, wrSectors: number, ioTicks: number, devices: string[] }}
 */
function parseDiskstats(content, targetDevices) {
  const result = {
    rdIos: 0,
    rdSectors: 0,
    wrIos: 0,
    wrSectors: 0,
    ioTicks: 0,
    devices: [],
  };
  if (!content || typeof content !== 'string') return result;

  let deviceSet = null;
  if (Array.isArray(targetDevices) && targetDevices.length > 0) {
    deviceSet = new Set(targetDevices.map(d => d.trim()));
  } else if (typeof targetDevices === 'string' && targetDevices.trim()) {
    deviceSet = new Set(targetDevices.split(',').map(d => d.trim()).filter(Boolean));
  }

  const lines = content.split(/\r?\n/);
  for (const line of lines) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 14) continue;

    const devName = parts[2];
    if (deviceSet) {
      if (!deviceSet.has(devName)) continue;
    } else {
      // Default filter: skip pseudo / loop / ram devices
      if (/^(loop|ram|zram|sr|fd|nbd)/.test(devName)) continue;
    }

    result.devices.push(devName);
    result.rdIos += parseInt(parts[3], 10) || 0;
    result.rdSectors += parseInt(parts[5], 10) || 0;
    result.wrIos += parseInt(parts[7], 10) || 0;
    result.wrSectors += parseInt(parts[9], 10) || 0;
    result.ioTicks += parseInt(parts[12], 10) || 0;
  }

  return result;
}

/**
 * Parse /proc/self/mountinfo to extract set of mount points.
 * Decodes octal escape sequences (e.g. \040 -> space).
 *
 * @param {string} content
 * @returns {Set<string>}
 */
function parseMountinfo(content) {
  const mountPoints = new Set();
  if (!content || typeof content !== 'string') return mountPoints;

  const lines = content.split(/\r?\n/);
  for (const line of lines) {
    if (!line.trim()) continue;
    const parts = line.trim().split(/\s+/);
    if (parts.length >= 5) {
      let mp = parts[4];
      mp = mp.replace(/\\([0-7]{3})/g, (_, oct) => String.fromCharCode(parseInt(oct, 8)));
      mountPoints.add(mp);
    }
  }
  return mountPoints;
}

/**
 * Parse output of zramctl command.
 *
 * @param {string} content
 * @returns {{ dev: string, algorithm: string, diskSize: number, data: number, compr: number, total: number, ratio: string }|null}
 */
function parseZramctl(content) {
  if (!content || typeof content !== 'string') return null;
  const line = content.trim().split(/\r?\n/)[0];
  if (!line) return null;

  const parts = line.trim().split(/\s+/);
  if (parts.length < 6) return null;

  const dev = parts[0];
  const algorithm = parts[1];
  const diskSize = parseInt(parts[2], 10) || 0;
  const data = parseInt(parts[3], 10) || 0;
  const compr = parseInt(parts[4], 10) || 0;
  const total = parseInt(parts[5], 10) || 0;
  const ratio = compr > 0 ? (data / compr).toFixed(2) : 'n/a';

  return { dev, algorithm, diskSize, data, compr, total, ratio };
}

/**
 * Parse /sys/block/<name>/mm_stat content.
 *
 * @param {string} content
 * @returns {{ origSize: number, comprSize: number, totalMem: number, ratio: string }|null}
 */
function parseMmStat(content) {
  if (!content || typeof content !== 'string') return null;
  const parts = content.trim().split(/\s+/);
  if (parts.length < 3) return null;

  const origSize = parseInt(parts[0], 10) || 0;
  const comprSize = parseInt(parts[1], 10) || 0;
  const totalMem = parseInt(parts[2], 10) || 0;
  const ratio = comprSize > 0 ? (origSize / comprSize).toFixed(2) : 'n/a';

  return { origSize, comprSize, totalMem, ratio };
}

/**
 * Map status string to emoji with label.
 *
 * @param {string} status
 * @returns {string}
 */
function statusEmoji(status) {
  if (!status) return '➖ disabled';
  const s = String(status).toLowerCase();
  if (s === 'active' || s === 'system' || s === 'global' || s === 'env') return '✅ ' + status;
  if (s === 'partial') return '⚠️ partial';
  if (s === 'failed' || s === 'unsupported') return '❌ ' + status;
  if (s === 'disabled') return '➖ disabled';
  if (s === 'skipped') return '⏭️ skipped';
  return escapeMarkdown(status);
}

/**
 * Retrieve zram swap information via zramctl or mm_stat.
 *
 * @param {string} devName
 * @param {Record<string, any>} state
 * @returns {Record<string, any>}
 */
function getZramInfo(devName, state = {}) {
  const targetDev = devName || state.ZRAM_DEV || '/dev/zram0';
  let algorithm = state.ZRAM_ALGO || 'lz4';
  let diskSize = state.ZRAM_SIZE || '50%';
  let dataBytes = 0;
  let comprBytes = 0;
  let totalBytes = 0;
  let ratio = 'n/a';

  let resolved = false;
  try {
    const out = child_process.execFileSync(
      'zramctl',
      ['--raw', '--bytes', '--noheadings', '--output', 'NAME,ALGORITHM,DISKSIZE,DATA,COMPR,TOTAL', targetDev],
      { encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'] }
    );
    const parsed = parseZramctl(out);
    if (parsed) {
      if (parsed.algorithm) algorithm = parsed.algorithm;
      if (parsed.diskSize) diskSize = formatBytes(parsed.diskSize);
      dataBytes = parsed.data;
      comprBytes = parsed.compr;
      totalBytes = parsed.total;
      ratio = parsed.ratio;
      resolved = true;
    }
  } catch {}

  if (!resolved) {
    const baseDev = path.basename(targetDev);
    const mmStatContent = safeReadFile(`/sys/block/${baseDev}/mm_stat`);
    if (mmStatContent) {
      const parsed = parseMmStat(mmStatContent);
      if (parsed) {
        dataBytes = parsed.origSize;
        comprBytes = parsed.comprSize;
        totalBytes = parsed.totalMem;
        ratio = parsed.ratio;
      }
    }
  }

  return {
    dev: targetDev,
    algorithm,
    diskSize: typeof diskSize === 'number' ? formatBytes(diskSize) : diskSize,
    data: formatBytes(dataBytes),
    compr: formatBytes(comprBytes),
    total: formatBytes(totalBytes),
    ratio: ratio !== 'n/a' ? `${ratio}:1` : 'n/a',
  };
}

/**
 * Pure telemetry computation helper.
 *
 * @param {object} params
 * @returns {object}
 */
function computeTelemetryData({
  baseline = {},
  state = {},
  nosyncStats = { skippedSync: 0, strippedOsync: 0, processes: 0 },
  currentCpuStat,
  currentMeminfoStr,
  currentVmstatStr,
  currentDiskstatsStr,
  currentUptimeStr,
  zramInfoOverride,
  nowMs = Date.now(),
}) {
  // 1. Elapsed time
  let elapsedMs = 0;
  if (baseline.START_EPOCH_MS) {
    elapsedMs = Math.max(0, nowMs - parseInt(baseline.START_EPOCH_MS, 10));
  } else if (baseline.START_UPTIME && currentUptimeStr) {
    const curUp = parseFloat(currentUptimeStr.trim().split(/\s+/)[0]) || 0;
    const baseUp = parseFloat(baseline.START_UPTIME) || 0;
    elapsedMs = Math.max(0, Math.round((curUp - baseUp) * 1000));
  }
  const elapsedSec = (elapsedMs / 1000).toFixed(2) + 's';

  // 2. CPU delta
  const cpuDelta = computeCpuDelta(baseline.CPU_STAT || '', currentCpuStat || '');

  // 3. Memory info
  const mem = parseMeminfo(currentMeminfoStr || '');
  const memAvailFormatted = `${formatBytes(mem.memAvailable)} / ${formatBytes(mem.memTotal)}`;
  const dirtyFormatted = formatBytes(mem.dirty);
  const writebackFormatted = formatBytes(mem.writeback);
  const cachedFormatted = formatBytes(mem.cached);
  const swapUsedFormatted = formatBytes(mem.swapUsed);

  // 4. Vmstat deltas
  const vm = parseVmstat(currentVmstatStr || '');
  const deltaNrDirtied = Math.max(0, (vm.nr_dirtied || 0) - (parseInt(baseline.VMSTAT_nr_dirtied, 10) || 0));
  const dataWrittenPageCache = formatBytes(deltaNrDirtied * 4096);
  const deltaPswpout = Math.max(0, (vm.pswpout || 0) - (parseInt(baseline.VMSTAT_pswpout, 10) || 0));
  const deltaOomKill = Math.max(0, (vm.oom_kill || 0) - (parseInt(baseline.VMSTAT_oom_kill, 10) || 0));
  const oomKillsFormatted = deltaOomKill === 0 ? '✅ 0' : `⚠️ ${deltaOomKill}`;

  // 5. Diskstats deltas
  const disk = parseDiskstats(currentDiskstatsStr || '', baseline.DISK_DEVICES || '');
  const deltaRdSectors = Math.max(0, disk.rdSectors - (parseInt(baseline.DISK_READ_SECTORS, 10) || 0));
  const deltaRdIos = Math.max(0, disk.rdIos - (parseInt(baseline.DISK_READ_IOS, 10) || 0));
  const deltaWrSectors = Math.max(0, disk.wrSectors - (parseInt(baseline.DISK_WRITE_SECTORS, 10) || 0));
  const deltaWrIos = Math.max(0, disk.wrIos - (parseInt(baseline.DISK_WRITE_IOS, 10) || 0));
  const deltaIoTicks = Math.max(0, disk.ioTicks - (parseInt(baseline.DISK_IO_TICKS_MS, 10) || 0));

  const diskWritesFormatted = `${formatBytes(deltaWrSectors * 512)} (${formatNumber(deltaWrIos)} IOs)`;
  const diskReadsFormatted = `${formatBytes(deltaRdSectors * 512)} (${formatNumber(deltaRdIos)} IOs)`;
  const diskBusyPct = elapsedMs > 0 ? Math.min(100, (deltaIoTicks / elapsedMs) * 100).toFixed(1) + '%' : '0.0%';

  // 6. Optimizations
  // Rows: fsync bypass (scope), page cache, remount, git (env), apt tuning, build env, zram swap, tmpfs paths, profile
  const optimizations = [];

  // fsync bypass
  const fsyncStatus = state.FSYNC_BYPASS || 'disabled';
  let fsyncDetail = 'disabled';
  if (fsyncStatus === 'active') {
    const scope = state.PRELOAD_SCOPE || 'env';
    fsyncDetail = `scope: ${scope} (${state.LD_PRELOAD_VALUE || 'libnosync.so'})`;
    if (state.FSYNC_COMPILE_MS) {
      fsyncDetail += ` [build: ${state.FSYNC_COMPILE_MS} ms]`;
    }
  } else if (fsyncStatus === 'failed') {
    fsyncDetail = 'gcc build or install failed';
  }
  optimizations.push({
    name: 'fsync bypass',
    rawStatus: fsyncStatus,
    status: statusEmoji(fsyncStatus),
    detail: fsyncDetail,
  });

  // page cache
  const cacheStatus = state.PAGE_CACHE || 'disabled';
  let cacheDetail = 'disabled';
  if (cacheStatus === 'active' || cacheStatus === 'partial') {
    const swappiness = state.ZRAM_SWAP === 'active' ? '100' : '10';
    cacheDetail = `dirty_ratio=45, dirty_background=15, swappiness=${swappiness}, vfs=50`;
  } else if (cacheStatus === 'skipped') {
    cacheDetail = 'non-root runner';
  }
  optimizations.push({
    name: 'page cache',
    rawStatus: cacheStatus,
    status: statusEmoji(cacheStatus),
    detail: cacheDetail,
  });

  // remount
  const remountStatus = state.REMOUNT || 'disabled';
  const remountDetail = state.REMOUNT_DETAIL || (remountStatus === 'active' ? 'noatime, barrier=0, commit=60' : 'disabled');
  optimizations.push({
    name: 'remount',
    rawStatus: remountStatus,
    status: statusEmoji(remountStatus),
    detail: remountDetail,
  });

  // git (env)
  const gitStatus = state.GIT_TUNING || 'disabled';
  let gitDetail = 'disabled';
  if (gitStatus === 'env') {
    gitDetail = 'env-based (untrackedCache, checkout.workers, fetch.parallel, auto-gc off)';
  } else if (gitStatus === 'skipped') {
    gitDetail = 'git < 2.31 or not found';
  }
  optimizations.push({
    name: 'git (env)',
    rawStatus: gitStatus,
    status: statusEmoji(gitStatus),
    detail: gitDetail,
  });

  // apt tuning
  const aptStatus = state.APT_TUNING || 'disabled';
  let aptDetail = 'disabled';
  if (aptStatus === 'active') {
    aptDetail = 'force-unsafe-io, acquire::languages=none, timers stopped';
  } else if (aptStatus === 'skipped') {
    aptDetail = 'non-root runner';
  }
  optimizations.push({
    name: 'apt tuning',
    rawStatus: aptStatus,
    status: statusEmoji(aptStatus),
    detail: aptDetail,
  });

  // build env
  const buildStatus = state.BUILD_ENV || 'disabled';
  let buildDetail = 'disabled';
  if (buildStatus === 'active') {
    buildDetail = 'MAKEFLAGS, CMAKE_BUILD_PARALLEL_LEVEL, CARGO_INCREMENTAL=0, CARGO_NET_GIT_FETCH_WITH_CLI';
  }
  optimizations.push({
    name: 'build env',
    rawStatus: buildStatus,
    status: statusEmoji(buildStatus),
    detail: buildDetail,
  });

  // zram swap
  const zramStatus = state.ZRAM_SWAP || 'disabled';
  let zramDetail = 'disabled';
  if (zramStatus === 'active') {
    zramDetail = `${state.ZRAM_DEV || '/dev/zram0'} (${state.ZRAM_SIZE || '50%'}, ${state.ZRAM_ALGO || 'lz4'})`;
  } else if (zramStatus === 'skipped') {
    zramDetail = 'non-root runner';
  } else if (zramStatus === 'unsupported') {
    zramDetail = 'zram module unavailable';
  }
  optimizations.push({
    name: 'zram swap',
    rawStatus: zramStatus,
    status: statusEmoji(zramStatus),
    detail: zramDetail,
  });

  // tmpfs paths
  const tmpfsStatus = state.TMPFS_PATHS || 'disabled';
  let tmpfsDetail = 'disabled';
  if (tmpfsStatus === 'active') {
    tmpfsDetail = state.TMPFS_DETAIL || state.TMPFS_MOUNTED || 'mounted';
  } else if (tmpfsStatus === 'skipped') {
    tmpfsDetail = 'non-root runner';
  }
  optimizations.push({
    name: 'tmpfs paths',
    rawStatus: tmpfsStatus,
    status: statusEmoji(tmpfsStatus),
    detail: tmpfsDetail,
  });

  // profile
  const profileStatus = state.PROFILE || 'hosted';
  optimizations.push({
    name: 'profile',
    rawStatus: profileStatus,
    status: statusEmoji(profileStatus),
    detail: profileStatus,
  });

  // 7. Telemetry metrics
  const telemetry = [
    { metric: 'Elapsed time', value: elapsedSec },
    { metric: 'CPU iowait avg', value: cpuDelta.iowaitPct },
    { metric: 'CPU user+sys', value: cpuDelta.userSysPct },
    { metric: 'Dirty now', value: dirtyFormatted },
    { metric: 'Writeback now', value: writebackFormatted },
    { metric: 'Memory available / total', value: memAvailFormatted },
    { metric: 'Page cache', value: cachedFormatted },
    { metric: 'Swap used', value: swapUsedFormatted },
    { metric: 'Data written to page cache (nr_dirtied)', value: dataWrittenPageCache },
    { metric: 'Physical disk writes', value: diskWritesFormatted },
    { metric: 'Physical disk reads', value: diskReadsFormatted },
    { metric: 'Disk busy %', value: diskBusyPct },
    { metric: 'Swap-out (pswpout)', value: `${formatNumber(deltaPswpout)} pages` },
    { metric: 'OOM kills', value: oomKillsFormatted },
  ];

  // 8. zram swap table
  let zramData = null;
  if (zramStatus === 'active') {
    zramData = zramInfoOverride || getZramInfo(state.ZRAM_DEV, state);
    zramData.active = true;
  }

  // 9. Footer
  const setupMs = state.SETUP_SCRIPT_MS || 'n/a';
  const arch = os.arch();
  const kernel = os.release();
  const runnerEnv = process.env.RUNNER_ENVIRONMENT || 'github-hosted';
  const footer = `Setup time: ${setupMs} ms | Architecture: ${arch} | Kernel: ${kernel} | Runner: ${runnerEnv}`;

  return {
    optimizations,
    nosyncImpact: nosyncStats,
    telemetry,
    zram: zramData,
    footer,
  };
}

/**
 * Generate full GitHub Step Summary Markdown string.
 *
 * @param {object} params
 * @returns {string}
 */
function generateMarkdown({ optimizations, nosyncImpact, telemetry, zram, footer }) {
  const lines = [];

  lines.push('## ⚡ overclock');
  lines.push('');

  // Table 1: Optimizations
  lines.push('### Optimizations');
  lines.push('');
  lines.push('| Optimization | Status | Detail |');
  lines.push('|---|---|---|');
  for (const opt of optimizations) {
    lines.push(`| ${escapeMarkdown(opt.name)} | ${escapeMarkdown(opt.status)} | ${escapeMarkdown(opt.detail)} |`);
  }
  lines.push('');

  // Table 2: fsync Bypass Impact (if any events or active)
  if (nosyncImpact && (nosyncImpact.skippedSync > 0 || nosyncImpact.strippedOsync > 0 || nosyncImpact.processes > 0)) {
    lines.push('### fsync Bypass Impact');
    lines.push('');
    lines.push('| Metric | Value |');
    lines.push('|---|---|');
    lines.push(`| Sync calls skipped | ${formatNumber(nosyncImpact.skippedSync)} |`);
    lines.push(`| O_SYNC / O_DSYNC stripped | ${formatNumber(nosyncImpact.strippedOsync)} |`);
    lines.push(`| Processes accelerated | ${formatNumber(nosyncImpact.processes)} |`);
    lines.push('');
  }

  // Table 3: System I/O Telemetry
  lines.push('### System I/O Telemetry');
  lines.push('');
  lines.push('| Metric | Value |');
  lines.push('|---|---|');
  for (const t of telemetry) {
    lines.push(`| ${escapeMarkdown(t.metric)} | ${escapeMarkdown(t.value)} |`);
  }
  lines.push('');

  // Table 4: zram Swap (if active)
  if (zram && zram.active) {
    lines.push('### zram Swap');
    lines.push('');
    lines.push('| Property | Value |');
    lines.push('|---|---|');
    lines.push(`| Device | ${escapeMarkdown(zram.dev)} |`);
    lines.push(`| Algorithm | ${escapeMarkdown(zram.algorithm)} |`);
    lines.push(`| Disk Size | ${escapeMarkdown(zram.diskSize)} |`);
    lines.push(`| Original Data | ${escapeMarkdown(zram.data)} |`);
    lines.push(`| Compressed Data | ${escapeMarkdown(zram.compr)} |`);
    lines.push(`| Compression Ratio | ${escapeMarkdown(zram.ratio)} |`);
    lines.push(`| Total Memory Used | ${escapeMarkdown(zram.total)} |`);
    lines.push('');
  }

  // Footer
  if (footer) {
    lines.push(`*${footer}*`);
    lines.push('');
  }

  return lines.join('\n');
}

/**
 * Generate compact console log telemetry string.
 *
 * @param {object} params
 * @returns {string}
 */
function generatePlainTextSummary({ optimizations, nosyncImpact, telemetry }) {
  const optSummary = optimizations.map(o => `${o.name}: ${o.rawStatus || o.status}`).join(' | ');
  const metricMap = {};
  for (const t of telemetry) {
    metricMap[t.metric] = t.value;
  }

  const lines = [
    '⚡ overclock telemetry summary:',
    `  Optimizations: ${optSummary}`,
  ];

  if (nosyncImpact && (nosyncImpact.skippedSync > 0 || nosyncImpact.strippedOsync > 0 || nosyncImpact.processes > 0)) {
    lines.push(
      `  fsync impact: skipped ${formatNumber(nosyncImpact.skippedSync)} sync calls, stripped ${formatNumber(nosyncImpact.strippedOsync)} O_SYNC flags across ${formatNumber(nosyncImpact.processes)} processes`
    );
  }

  lines.push(
    `  I/O: writes=${metricMap['Physical disk writes'] || 'n/a'}, reads=${metricMap['Physical disk reads'] || 'n/a'}, disk-busy=${metricMap['Disk busy %'] || '0.0%'}, iowait=${metricMap['CPU iowait avg'] || '0.0%'}`
  );
  lines.push(
    `  Memory: available/total=${metricMap['Memory available / total'] || 'n/a'}, dirty=${metricMap['Dirty now'] || 'n/a'}, page-cache=${metricMap['Page cache'] || 'n/a'}`
  );
  lines.push(`  Elapsed: ${metricMap['Elapsed time'] || '0.00s'}`);

  return lines.join('\n');
}

/**
 * Main execution of post hook.
 */
function run() {
  try {
    if (process.platform !== 'linux') {
      return;
    }

    const stateDir =
      process.env.STATE_state_dir ||
      (process.env.RUNNER_TEMP ? path.join(process.env.RUNNER_TEMP, 'overclock') : path.join(os.tmpdir(), 'overclock'));

    const stateFile = path.join(stateDir, 'state.env');
    const metricsFile = path.join(stateDir, 'metrics-start.env');
    const statsFile = path.join(stateDir, 'nosync-stats');

    const rawSummary =
      process.env.STATE_summary !== undefined ? process.env.STATE_summary : (process.env.INPUT_SUMMARY || 'true');
    const summaryEnabled = parseBool(rawSummary, true);

    const baselineRaw = safeReadFile(metricsFile);
    const baseline = parseEnvFile(baselineRaw || '');
    const stateRaw = safeReadFile(stateFile);
    const state = parseEnvFile(stateRaw || '');

    const nosyncRaw = safeReadFile(statsFile);
    const nosyncStats = parseNosyncStats(nosyncRaw || '');

    const currentCpuStat = safeReadFile('/proc/stat');
    const currentMeminfo = safeReadFile('/proc/meminfo');
    const currentVmstat = safeReadFile('/proc/vmstat');
    const currentDiskstats = safeReadFile('/proc/diskstats');
    const currentUptime = safeReadFile('/proc/uptime');

    const data = computeTelemetryData({
      baseline,
      state,
      nosyncStats,
      currentCpuStat,
      currentMeminfoStr: currentMeminfo,
      currentVmstatStr: currentVmstat,
      currentDiskstatsStr: currentDiskstats,
      currentUptimeStr: currentUptime,
    });

    const plainText = generatePlainTextSummary(data);
    console.log(plainText);

    if (summaryEnabled && process.env.GITHUB_STEP_SUMMARY) {
      const markdown = generateMarkdown(data);
      appendGithubSummary(markdown);
    }

    // Self-hosted teardown if applicable
    const runnerEnv = process.env.RUNNER_ENVIRONMENT || 'github-hosted';
    const isPrivileged = parseBool(process.env.STATE_privileged, false);
    if (runnerEnv === 'self-hosted' && isPrivileged) {
      const actionPath = path.resolve(__dirname, '..');
      const teardownEnv = {
        OVERCLOCK_STATE_DIR: stateDir,
      };
      runRootScript(path.join(actionPath, 'src', 'setup-linux.sh'), ['teardown'], teardownEnv);
    }
  } catch (err) {
    const msg = err && err.message ? err.message : String(err);
    console.log(`::warning title=overclock::Post step encountered an error: ${msg}`);
  }
}

if (require.main === module) {
  run();
}

module.exports = {
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
  getZramInfo,
  computeTelemetryData,
  generateMarkdown,
  generatePlainTextSummary,
  run,
};
