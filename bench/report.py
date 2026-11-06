#!/usr/bin/env python3
"""bench/report.py - Generate markdown benchmark report with statistical analysis.

Uses Python stdlib only. Computes median, IQR, speedup vs baseline, bootstrap
95% CI (2000 resamples), and significance for each workload and configuration.
Outputs markdown to stdout, saves to bench-report.md, and appends to
$GITHUB_STEP_SUMMARY if set.
"""

import glob
import json
import os
import random
import statistics
import sys


def compute_median(data):
    if not data:
        return 0.0
    return float(statistics.median(data))


def compute_iqr(data):
    if not data or len(data) < 2:
        return 0.0
    try:
        q = statistics.quantiles(data, n=4, method="inclusive")
        return float(q[2] - q[0])
    except Exception:
        return 0.0


def compute_bootstrap_ci(base_samples, test_samples, n_resamples=2000, alpha=0.05):
    """Compute bootstrap confidence interval for ratio: median(base) / median(test)."""
    if not base_samples or not test_samples:
        return None, None

    n_base = len(base_samples)
    n_test = len(test_samples)
    ratios = []

    # Deterministic seed for reproducible reports given identical inputs
    rng = random.Random(42)

    for _ in range(n_resamples):
        b_sample = rng.choices(base_samples, k=n_base)
        t_sample = rng.choices(test_samples, k=n_test)
        b_med = statistics.median(b_sample)
        t_med = statistics.median(t_sample)
        if t_med > 0:
            ratios.append(b_med / t_med)
        else:
            ratios.append(1.0)

    ratios.sort()
    idx_low = int((alpha / 2.0) * len(ratios))
    idx_high = int((1.0 - alpha / 2.0) * len(ratios))
    # Clamp bounds
    idx_low = max(0, min(idx_low, len(ratios) - 1))
    idx_high = max(0, min(idx_high, len(ratios) - 1))

    return ratios[idx_low], ratios[idx_high]


def format_ms(val):
    if val >= 10000:
        return f"{val:,.0f} ms"
    return f"{val:,.1f} ms"


def main():
    # Gather input files from arguments or globs
    files = []
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            matched = glob.glob(arg)
            if matched:
                files.extend(matched)
            elif os.path.isfile(arg):
                files.append(arg)
    else:
        files = glob.glob("results/*.json") or glob.glob("*.json")

    files = sorted(set(files))

    if not files:
        msg = "No benchmark results found."
        print(msg)
        summary_env = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_env:
            with open(summary_env, "a", encoding="utf-8") as f:
                f.write(f"## ⚡ Benchmark Report\n\n{msg}\n")
        return 0

    records = []
    for filepath in files:
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = json.load(f)
                records.append(data)
        except Exception as exc:
            print(f"Warning: could not parse {filepath}: {exc}", file=sys.stderr)

    if not records:
        print("No valid benchmark records could be parsed.", file=sys.stderr)
        return 0

    # Group by runner and arch: runner_key -> list of records
    grouped_by_runner = {}
    for r in records:
        runner = r.get("runner", "unknown")
        arch = r.get("arch", "")
        runner_key = f"{runner} ({arch})" if arch else runner
        grouped_by_runner.setdefault(runner_key, []).append(r)

    # Standard configuration presentation order
    config_order = ["baseline", "fsync", "kernel", "all"]

    report_lines = []
    report_lines.append("# ⚡ Overclock Benchmark Report")
    report_lines.append("")
    report_lines.append("Interleaved in-VM A/B benchmark results across configurations and runners.")
    report_lines.append("- **baseline**: standard runner environment (all overclock optimizations off)")
    report_lines.append("- **fsync**: libnosync fsync bypass only")
    report_lines.append("- **kernel**: sysctl page cache tuning + barrier=0/commit=60 remount")
    report_lines.append("- **all**: full overclock suite (fsync bypass + kernel + apt optimizations)")
    report_lines.append("")

    for runner_key in sorted(grouped_by_runner.keys()):
        report_lines.append(f"## Runner: `{runner_key}`")
        report_lines.append("")
        report_lines.append(
            "| Workload | Config | Median ms | IQR | Speedup vs Baseline | 95% Bootstrap CI | Significant? | Fsyncs Skipped |"
        )
        report_lines.append(
            "|:---|:---|---:|---:|---:|:---:|:---:|---:|"
        )

        runner_records = grouped_by_runner[runner_key]
        # Sort workloads by name
        runner_records.sort(key=lambda x: x.get("workload", ""))

        for rec in runner_records:
            workload = rec.get("workload", "unknown")
            results = rec.get("results", {})
            skipped_map = rec.get("skipped_fsyncs", {})

            base_samples = results.get("baseline", [])
            base_median = compute_median(base_samples)

            # Discover available configs, preserving standard order then any extra
            available_configs = [c for c in config_order if c in results]
            for c in sorted(results.keys()):
                if c not in available_configs:
                    available_configs.append(c)

            for cfg in available_configs:
                samples = results.get(cfg, [])
                if not samples:
                    continue

                med = compute_median(samples)
                iqr = compute_iqr(samples)
                med_str = format_ms(med)
                iqr_str = format_ms(iqr)

                skipped_val = skipped_map.get(cfg, 0)
                skipped_str = f"{skipped_val:,}"

                if cfg == "baseline":
                    speedup_str = "1.00x"
                    ci_str = "-"
                    sig_str = "-"
                else:
                    if med > 0 and base_median > 0:
                        ratio = base_median / med
                        speedup_str = f"**{ratio:.2f}x**" if ratio >= 1.05 else f"{ratio:.2f}x"
                    else:
                        speedup_str = "n/a"

                    ci_low, ci_high = compute_bootstrap_ci(base_samples, samples)
                    if ci_low is not None and ci_high is not None:
                        ci_str = f"[{ci_low:.2f}x, {ci_high:.2f}x]"
                        # Speedups whose CI includes 1.0 are marked not significant
                        if ci_low <= 1.0 <= ci_high:
                            sig_str = "No"
                        else:
                            sig_str = "**Yes**"
                    else:
                        ci_str = "n/a"
                        sig_str = "n/a"

                report_lines.append(
                    f"| {workload} | {cfg} | {med_str} | {iqr_str} | {speedup_str} | {ci_str} | {sig_str} | {skipped_str} |"
                )

        report_lines.append("")

    full_report = "\n".join(report_lines)
    print(full_report)

    # Save to bench-report.md
    out_file = "bench-report.md"
    try:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write(full_report + "\n")
        print(f"\nSaved report to {out_file}")
    except Exception as exc:
        print(f"Warning: could not write {out_file}: {exc}", file=sys.stderr)

    # Append to GITHUB_STEP_SUMMARY if available
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        try:
            with open(summary_path, "a", encoding="utf-8") as f:
                f.write(full_report + "\n")
        except Exception as exc:
            print(f"Warning: could not write to GITHUB_STEP_SUMMARY: {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
