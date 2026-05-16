#!/usr/bin/env bash
# gpu_monitor.sh — Jetson GPU/RAM/thermal sample window wrapper.
#
# Purpose:
#   Run tegrastats for a fixed duration and print summary statistics
#   (GR3D_FREQ min/max/median/p95, peak RAM_MB, peak temperatures).
#
# Usage:
#   ./gpu_monitor.sh [duration_seconds] [log_file]
#
# Args:
#   duration_seconds  Sampling duration in seconds (default: 60)
#   log_file          Output tegrastats log path
#                     (default: /tmp/gpu_monitor_<YYYYMMDD_HHMMSS>.log)
#
# Deps: tegrastats, awk, sort, bc

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [duration_seconds] [log_file]

  duration_seconds  Default: 60
  log_file          Default: /tmp/gpu_monitor_<YYYYMMDD_HHMMSS>.log

Example:
  $(basename "$0") 120 /tmp/my_gpu.log
  $(basename "$0") 300
EOF
}

# Print usage if explicit -h/--help (no-args case still runs with defaults)
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

DURATION="${1:-60}"
TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${2:-/tmp/gpu_monitor_${TS}.log}"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
    echo "Error: duration_seconds must be an integer (got '$DURATION')" >&2
    usage
    exit 1
fi

# ---- ANSI colors ----
if [ -t 1 ]; then
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

log_info() { echo "${C_BLUE}[INFO]${C_RESET} $*"; }

# ---- run tegrastats ----
log_info "tegrastats sampling for ${DURATION}s → $LOG_FILE"
tegrastats --interval 1000 --logfile "$LOG_FILE" &
TEGRA_PID=$!
trap 'kill "$TEGRA_PID" 2>/dev/null || true' EXIT INT TERM

sleep "$DURATION"

kill "$TEGRA_PID" 2>/dev/null || true
wait "$TEGRA_PID" 2>/dev/null || true
trap - EXIT INT TERM

if [[ ! -s "$LOG_FILE" ]]; then
    echo "Error: tegrastats log is empty: $LOG_FILE" >&2
    exit 2
fi

# ---- parsing helpers ----
# GR3D_FREQ percentages — tegrastats prints e.g. "GR3D_FREQ 12%"
gr3d_values() {
    grep -oE 'GR3D_FREQ [0-9]+%' "$LOG_FILE" \
        | awk '{gsub("%","",$2); print $2}'
}

# RAM_MB — tegrastats prints e.g. "RAM 5432/15819MB"
ram_values() {
    grep -oE 'RAM [0-9]+/[0-9]+MB' "$LOG_FILE" \
        | awk '{split($2,a,"/"); print a[1]}'
}

# Temperatures: "cpu@45.5C gpu@47.0C tj@48.2C ..." etc.
temp_values() {
    local zone="$1"
    grep -oE "${zone}@[0-9]+(\.[0-9]+)?C" "$LOG_FILE" \
        | awk -F'[@C]' '{print $2}'
}

# Stats helpers
stats_min_max_med_p95() {
    # reads numbers on stdin, outputs: min max median p95 (whitespace-separated)
    sort -n | awk '
        { a[NR]=$1 }
        END {
            n=NR
            if (n==0) { print "0 0 0 0"; exit }
            min=a[1]; max=a[n]
            if (n%2==1) med=a[(n+1)/2]
            else med=(a[n/2]+a[n/2+1])/2
            p95_idx = int(0.95*n + 0.999999)
            if (p95_idx<1) p95_idx=1
            if (p95_idx>n) p95_idx=n
            p95=a[p95_idx]
            printf("%g %g %g %g\n", min, max, med, p95)
        }
    '
}

max_val() {
    sort -n | tail -n1 | awk '{print ($1=="" ? "0" : $1)}'
}

# ---- compute ----
GR3D_STATS="$(gr3d_values | stats_min_max_med_p95)"
GR3D_MIN="$(echo "$GR3D_STATS" | awk '{print $1}')"
GR3D_MAX="$(echo "$GR3D_STATS" | awk '{print $2}')"
GR3D_MED="$(echo "$GR3D_STATS" | awk '{print $3}')"
GR3D_P95="$(echo "$GR3D_STATS" | awk '{print $4}')"

RAM_MAX="$(ram_values | max_val)"

CPU_TMAX="$(temp_values cpu | max_val)"
GPU_TMAX="$(temp_values gpu | max_val)"
TJ_TMAX="$(temp_values tj  | max_val)"

SAMPLES="$(gr3d_values | wc -l | awk '{print $1}')"

# ---- print summary ----
echo ""
echo "==============================================================="
echo " GPU MONITOR SUMMARY"
echo "==============================================================="
echo " Log file:        $LOG_FILE"
echo " Duration:        ${DURATION}s"
echo " GR3D samples:    $SAMPLES"
echo "---------------------------------------------------------------"
printf " GR3D_FREQ  min=%5s%%  max=%5s%%  median=%5s%%  p95=%5s%%\n" \
    "$GR3D_MIN" "$GR3D_MAX" "$GR3D_MED" "$GR3D_P95"
printf " RAM_MB     max=%s MB\n" "$RAM_MAX"
printf " Temp(C)    cpu_max=%s  gpu_max=%s  tj_max=%s\n" \
    "$CPU_TMAX" "$GPU_TMAX" "$TJ_TMAX"
echo "==============================================================="

# Highlight thermal warnings
TJ_HOT="$(echo "${TJ_TMAX:-0} >= 85" | bc -l 2>/dev/null || echo 0)"
if [[ "$TJ_HOT" == "1" ]]; then
    echo "${C_YELLOW}[WARN]${C_RESET} tj temperature reached ${TJ_TMAX}C (>=85C)"
fi
GPU_HOT="$(echo "${GPU_TMAX:-0} >= 80" | bc -l 2>/dev/null || echo 0)"
if [[ "$GPU_HOT" == "1" ]]; then
    echo "${C_YELLOW}[WARN]${C_RESET} GPU temperature reached ${GPU_TMAX}C (>=80C)"
fi
if [[ "$TJ_HOT" != "1" && "$GPU_HOT" != "1" ]]; then
    echo "${C_GREEN}[OK]${C_RESET} Thermals within bounds."
fi
