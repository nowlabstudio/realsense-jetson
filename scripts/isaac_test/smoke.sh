#!/usr/bin/env bash
# smoke.sh — Isaac Humble heterogeneous stack H6 smoke test.
#
# Purpose:
#   Validate that the ros2_realsense_isaac container (Humble + Isaac 3.2)
#   publishes the expected D435i topics at expected rates, exercises the
#   NITROS GPU pointcloud pipeline, and remains stable under a 20-minute
#   stress block. Collects all results (does NOT exit on individual FAILs).
#
# Usage:
#   ./smoke.sh
#
# Total runtime: ~30 minutes (5 min tegrastats + 20 min stress + overhead).
#
# Deps:
#   - docker (with ros2_realsense_isaac container Up)
#   - tegrastats (Jetson)
#   - bc (for floating-point math)
#   - awk, grep, timeout
#
# Env vars:
#   ISAAC_CONTAINER  (default: ros2_realsense_isaac)
#   HZ_SAMPLE_SEC    (default: 30) — duration per ros2 topic hz sample
#   TEGRA_DURATION   (default: 300) — initial GPU sample window (sec)
#   STRESS_DURATION  (default: 1200) — stress block duration (sec)
#   RESULTS_DIR      (default: /tmp/isaac_smoke_<timestamp>)

set -euo pipefail

ISAAC_CONTAINER="${ISAAC_CONTAINER:-ros2_realsense_isaac}"
HZ_SAMPLE_SEC="${HZ_SAMPLE_SEC:-30}"
TEGRA_DURATION="${TEGRA_DURATION:-300}"
STRESS_DURATION="${STRESS_DURATION:-1200}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="${RESULTS_DIR:-/tmp/isaac_smoke_${TIMESTAMP}}"
HUMBLE_POINTCLOUD_RATE_FILE="/tmp/humble_pointcloud_rate.txt"

mkdir -p "$RESULTS_DIR"
SUMMARY_FILE="$RESULTS_DIR/summary.txt"

# ---- ANSI colors (degrade on non-TTY) ----
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

# ---- result tracking arrays ----
RESULT_NAMES=()
RESULT_VALUES=()
RESULT_VERDICTS=()
RESULT_NOTES=()

record() {
    # record <name> <verdict: PASS|FAIL|WARN> <value> <note>
    RESULT_NAMES+=("$1")
    RESULT_VERDICTS+=("$2")
    RESULT_VALUES+=("$3")
    RESULT_NOTES+=("$4")
}

log_info()  { echo "${C_BLUE}[INFO]${C_RESET}  $*"; }
log_pass()  { echo "${C_GREEN}[PASS]${C_RESET}  $*"; }
log_fail()  { echo "${C_RED}[FAIL]${C_RESET}  $*"; }
log_warn()  { echo "${C_YELLOW}[WARN]${C_RESET}  $*"; }

# ---- expected topics + expected rates (Hz) ----
EXPECTED_TOPICS=(
    "/camera/color/image_raw:30:5"
    "/camera/depth/image_rect_raw:30:5"
    "/camera/infra1/image_rect_raw:30:5"
    "/camera/infra2/image_rect_raw:30:5"
    "/camera/accel/sample:63:8"
    "/camera/gyro/sample:200:25"
    "/camera/imu/data:200:25"
    "/camera/depth/points:27:5"
)

# ---- Step 1: container Up check ----
check_container_up() {
    log_info "Step 1/6 — Verify $ISAAC_CONTAINER is Up..."
    local status
    status="$(docker ps --filter "name=${ISAAC_CONTAINER}" --format '{{.Status}}' 2>&1 || true)"
    if [[ "$status" =~ ^Up\  ]]; then
        log_pass "Container Up: $status"
        record "container_up" "PASS" "$status" ""
    else
        log_fail "Container NOT Up: '$status'"
        record "container_up" "FAIL" "$status" "container not running"
        return 1
    fi
    return 0
}

# ---- Step 2: topic list ----
check_topic_list() {
    log_info "Step 2/6 — Verify expected topics in container..."
    local topic_list_file="$RESULTS_DIR/topic_list.txt"
    if ! docker exec "$ISAAC_CONTAINER" bash -c \
            "source /opt/ros/humble/setup.bash && ros2 topic list" \
            > "$topic_list_file" 2>&1; then
        log_fail "ros2 topic list failed (see $topic_list_file)"
        record "topic_list" "FAIL" "exec failed" ""
        return
    fi

    local missing=()
    for entry in "${EXPECTED_TOPICS[@]}"; do
        local topic="${entry%%:*}"
        if ! grep -qx "$topic" "$topic_list_file"; then
            missing+=("$topic")
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        log_pass "All 8 expected topics present"
        record "topic_list" "PASS" "8/8" ""
    else
        log_fail "Missing topics: ${missing[*]}"
        record "topic_list" "FAIL" \
            "$((${#EXPECTED_TOPICS[@]} - ${#missing[@]}))/${#EXPECTED_TOPICS[@]}" \
            "missing: ${missing[*]}"
    fi
}

# ---- Step 3: topic rates ----
measure_topic_rate() {
    # Returns avg rate (Hz) on stdout, or "0" on failure.
    local topic="$1"
    local out
    out="$(docker exec "$ISAAC_CONTAINER" bash -c \
        "source /opt/ros/humble/setup.bash && \
         timeout ${HZ_SAMPLE_SEC} ros2 topic hz '${topic}' 2>&1 || true")"
    # ros2 topic hz prints lines like:
    # "average rate: 29.998"
    local avg
    avg="$(echo "$out" | awk '/average rate:/ {val=$3} END {if (val=="") print 0; else print val}')"
    if [[ -z "$avg" ]]; then avg="0"; fi
    echo "$avg"
}

check_topic_rates() {
    log_info "Step 3/6 — Measure topic rates (${HZ_SAMPLE_SEC}s each)..."
    local pointcloud_rate=""
    for entry in "${EXPECTED_TOPICS[@]}"; do
        local topic="${entry%%:*}"
        local rest="${entry#*:}"
        local expected="${rest%%:*}"
        local tolerance="${rest##*:}"
        log_info "  Measuring $topic (expected ${expected}±${tolerance} Hz)..."
        local rate
        rate="$(measure_topic_rate "$topic")"
        local rate_int
        rate_int="${rate%.*}"
        if [[ -z "$rate_int" || "$rate_int" == "0" ]]; then
            log_fail "  $topic: no messages (rate=$rate)"
            record "rate:$topic" "FAIL" "$rate Hz" "no messages"
            continue
        fi
        # PASS if within tolerance OR (for color/depth/infra) ≥ expected-tol
        local diff
        diff="$(echo "$rate - $expected" | bc -l 2>/dev/null || echo 0)"
        local abs_diff
        abs_diff="${diff#-}"
        local within
        within="$(echo "$abs_diff <= $tolerance" | bc -l 2>/dev/null || echo 0)"
        if [[ "$within" == "1" ]]; then
            log_pass "  $topic: ${rate} Hz (expected ${expected}±${tolerance})"
            record "rate:$topic" "PASS" "$rate Hz" "expected ${expected}±${tolerance}"
        else
            log_warn "  $topic: ${rate} Hz outside ${expected}±${tolerance}"
            record "rate:$topic" "WARN" "$rate Hz" "expected ${expected}±${tolerance}"
        fi
        if [[ "$topic" == "/camera/depth/points" ]]; then
            pointcloud_rate="$rate"
        fi
    done
    # Persist pointcloud rate for cross_distro_check.py
    if [[ -n "$pointcloud_rate" ]]; then
        echo "$pointcloud_rate" > "$HUMBLE_POINTCLOUD_RATE_FILE"
        log_info "Wrote pointcloud rate to $HUMBLE_POINTCLOUD_RATE_FILE: $pointcloud_rate Hz"
    fi
}

# ---- Step 4: tegrastats (5 min) ----
parse_gr3d_from_log() {
    # Echoes whitespace-separated list of GR3D_FREQ percentages.
    local log="$1"
    grep -oE 'GR3D_FREQ [0-9]+%' "$log" 2>/dev/null \
        | awk '{gsub("%","",$2); print $2}' \
        || true
}

percentile_p() {
    # percentile_p <p (0-100)> < sorted-numbers-on-stdin
    # Reads numbers from stdin, prints the p-th percentile (nearest-rank).
    local p="$1"
    awk -v p="$p" '
        { a[NR]=$1 }
        END {
            n=NR
            if (n==0) { print "0"; exit }
            idx = int((p/100.0)*n + 0.999999)
            if (idx<1) idx=1
            if (idx>n) idx=n
            print a[idx]
        }
    '
}

median() {
    sort -n | awk '
        { a[NR]=$1 }
        END {
            n=NR
            if (n==0) { print "0"; exit }
            if (n%2==1) print a[(n+1)/2]
            else printf("%.2f\n", (a[n/2]+a[n/2+1])/2)
        }
    '
}

run_tegrastats_gpu_check() {
    log_info "Step 4/6 — tegrastats for ${TEGRA_DURATION}s (GPU activity check)..."
    local tegra_log="$RESULTS_DIR/tegrastats_gpu.log"
    tegrastats --interval 1000 --logfile "$tegra_log" &
    local tegra_pid=$!
    sleep "$TEGRA_DURATION"
    kill "$tegra_pid" 2>/dev/null || true
    wait "$tegra_pid" 2>/dev/null || true

    local values_file="$RESULTS_DIR/gr3d_values.txt"
    parse_gr3d_from_log "$tegra_log" > "$values_file"
    local count
    count="$(wc -l < "$values_file" | awk '{print $1}')"
    if [[ "$count" -eq 0 ]]; then
        log_fail "tegrastats produced no GR3D_FREQ samples"
        record "gpu_gr3d" "FAIL" "0 samples" "tegrastats log empty"
        return
    fi

    local sorted="$RESULTS_DIR/gr3d_sorted.txt"
    sort -n "$values_file" > "$sorted"
    local gpu_median gpu_peak gpu_p95
    gpu_median="$(median < "$sorted")"
    gpu_peak="$(tail -n1 "$sorted")"
    gpu_p95="$(percentile_p 95 < "$sorted")"

    local median_ok peak_ok
    median_ok="$(echo "$gpu_median > 5" | bc -l 2>/dev/null || echo 0)"
    peak_ok="$(echo "$gpu_peak > 20" | bc -l 2>/dev/null || echo 0)"

    local verdict="PASS"
    local note="median>5%, peak>20%"
    if [[ "$median_ok" != "1" || "$peak_ok" != "1" ]]; then
        verdict="FAIL"
        note="median=$gpu_median%, peak=$gpu_peak% (need median>5, peak>20)"
        log_fail "GPU activity below NITROS expectation: $note"
    else
        log_pass "GPU activity OK: median=${gpu_median}%, p95=${gpu_p95}%, peak=${gpu_peak}%"
    fi
    record "gpu_gr3d" "$verdict" \
        "median=${gpu_median}%, p95=${gpu_p95}%, peak=${gpu_peak}%" \
        "$note"
}

# ---- Step 5: docker stats RAM ----
check_docker_ram() {
    log_info "Step 5/6 — docker stats RAM totals..."
    local stats_file="$RESULTS_DIR/docker_stats.txt"
    docker stats --no-stream --format "{{.Container}}: {{.MemUsage}}" \
        > "$stats_file" 2>&1 || true
    cat "$stats_file"

    # Parse mem in MiB/GiB from "1.234GiB / ..." or "456.7MiB / ..."
    local total_mib
    total_mib="$(awk '
        {
            # field 2 is like "1.234GiB" (followed by "/" and limit)
            for (i=1;i<=NF;i++) {
                if (match($i, /^[0-9.]+(MiB|GiB|KiB|B)$/)) {
                    val=substr($i, 1, RLENGTH-3)
                    unit=substr($i, RLENGTH-2)
                    if (unit=="GiB") sum += val*1024
                    else if (unit=="MiB") sum += val
                    else if (unit=="KiB") sum += val/1024
                    break
                }
            }
        }
        END { printf("%.1f\n", sum+0) }
    ' "$stats_file")"

    local total_gib
    total_gib="$(echo "scale=2; $total_mib / 1024" | bc -l 2>/dev/null || echo 0)"
    local ram_ok
    ram_ok="$(echo "$total_gib < 6" | bc -l 2>/dev/null || echo 0)"
    if [[ "$ram_ok" == "1" ]]; then
        log_pass "Total RAM across containers: ${total_gib} GiB (<6 GiB)"
        record "ram_total" "PASS" "${total_gib} GiB" "<6 GiB threshold"
    else
        log_fail "Total RAM ${total_gib} GiB exceeds 6 GiB threshold"
        record "ram_total" "FAIL" "${total_gib} GiB" "exceeds 6 GiB"
    fi
}

# ---- Step 6: 20-min stress block ----
run_stress_block() {
    log_info "Step 6/6 — 20-min stress block (${STRESS_DURATION}s)..."

    local restart_before
    restart_before="$(docker inspect --format '{{.RestartCount}}' \
        "$ISAAC_CONTAINER" 2>/dev/null || echo 0)"
    log_info "  Initial RestartCount: $restart_before"

    # Run tegrastats during stress
    local stress_tegra="$RESULTS_DIR/tegrastats_stress.log"
    tegrastats --interval 1000 --logfile "$stress_tegra" &
    local tegra_pid=$!

    # Periodically sample pointcloud rate during stress
    local rate_log="$RESULTS_DIR/pointcloud_rate_stress.log"
    : > "$rate_log"
    local start_ts elapsed
    start_ts="$(date +%s)"
    local samples=0
    while true; do
        elapsed=$(( $(date +%s) - start_ts ))
        if [[ "$elapsed" -ge "$STRESS_DURATION" ]]; then break; fi
        local rate
        rate="$(measure_topic_rate /camera/depth/points)"
        echo "${elapsed} ${rate}" >> "$rate_log"
        samples=$((samples + 1))
        log_info "  [stress t=${elapsed}s] /camera/depth/points = ${rate} Hz"
    done

    kill "$tegra_pid" 2>/dev/null || true
    wait "$tegra_pid" 2>/dev/null || true

    local restart_after
    restart_after="$(docker inspect --format '{{.RestartCount}}' \
        "$ISAAC_CONTAINER" 2>/dev/null || echo 0)"
    local restart_delta=$((restart_after - restart_before))
    log_info "  Final RestartCount: $restart_after (delta=$restart_delta)"

    # Check for CUDA / error in docker logs since stress started
    local err_log="$RESULTS_DIR/docker_errors.log"
    docker logs --since "${STRESS_DURATION}s" "$ISAAC_CONTAINER" 2>&1 \
        | grep -iE 'cuda|error|dlopen' > "$err_log" || true
    local cuda_dlopen_count
    cuda_dlopen_count="$(grep -cE 'CUDA.*dlopen|dlopen.*CUDA' "$err_log" || true)"

    # Stability of pointcloud rate (±10%)
    local first_rate last_rate stability_ok="0"
    first_rate="$(awk 'NR==1 {print $2}' "$rate_log")"
    last_rate="$(awk 'END {print $2}' "$rate_log")"
    if [[ -n "$first_rate" && -n "$last_rate" && \
          "$(echo "$first_rate > 0" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
        local drift_pct
        drift_pct="$(echo "scale=2; ((${last_rate} - ${first_rate}) / ${first_rate}) * 100" | bc -l)"
        local abs_drift="${drift_pct#-}"
        stability_ok="$(echo "$abs_drift <= 10" | bc -l 2>/dev/null || echo 0)"
        log_info "  Pointcloud drift: ${first_rate}→${last_rate} Hz (${drift_pct}%)"
    fi

    local verdict="PASS"
    local note=""
    if [[ "$restart_delta" -ne 0 ]]; then
        verdict="FAIL"
        note="restarts=$restart_delta"
    fi
    if [[ "$cuda_dlopen_count" -gt 0 ]]; then
        verdict="FAIL"
        note="${note}; cuda_dlopen=$cuda_dlopen_count"
    fi
    if [[ "$stability_ok" != "1" ]]; then
        verdict="FAIL"
        note="${note}; pointcloud drift >10%"
    fi
    if [[ "$verdict" == "PASS" ]]; then
        log_pass "Stress block stable: 0 restarts, 0 CUDA dlopen errors, rate ±10%"
    else
        log_fail "Stress block issues: $note"
    fi
    record "stress_20min" "$verdict" \
        "restarts=$restart_delta, cuda_dlopen=$cuda_dlopen_count, samples=$samples" \
        "$note"
}

# ---- Final summary table ----
print_summary() {
    {
        echo ""
        echo "==============================================================="
        echo " ISAAC HUMBLE SMOKE TEST — H6 SUMMARY  ($TIMESTAMP)"
        echo "==============================================================="
        printf "%-30s %-6s %-40s %s\n" "TEST" "VERDICT" "VALUE" "NOTE"
        echo "---------------------------------------------------------------"
        local pass_count=0 fail_count=0 warn_count=0
        for i in "${!RESULT_NAMES[@]}"; do
            local v="${RESULT_VERDICTS[$i]}"
            local color="$C_RESET"
            case "$v" in
                PASS) color="$C_GREEN"; pass_count=$((pass_count + 1)) ;;
                FAIL) color="$C_RED";   fail_count=$((fail_count + 1)) ;;
                WARN) color="$C_YELLOW"; warn_count=$((warn_count + 1)) ;;
            esac
            printf "%-30s ${color}%-6s${C_RESET} %-40s %s\n" \
                "${RESULT_NAMES[$i]}" "$v" "${RESULT_VALUES[$i]}" "${RESULT_NOTES[$i]}"
        done
        echo "---------------------------------------------------------------"
        echo " TOTAL: ${pass_count} PASS, ${warn_count} WARN, ${fail_count} FAIL"
        echo " Results dir: $RESULTS_DIR"
        echo "==============================================================="
    } | tee "$SUMMARY_FILE"
}

# ---- main ----
main() {
    log_info "Isaac Humble smoke test starting — results dir: $RESULTS_DIR"
    if ! check_container_up; then
        print_summary
        exit 1
    fi
    check_topic_list || true
    check_topic_rates || true
    run_tegrastats_gpu_check || true
    check_docker_ram || true
    run_stress_block || true
    print_summary
}

main "$@"
