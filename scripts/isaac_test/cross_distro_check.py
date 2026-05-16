#!/usr/bin/env python3
"""cross_distro_check.py — Isaac Humble heterogeneous stack H7 validation.

Purpose:
    Verify that the Jazzy main stack (container `robot`) sees Humble-side
    camera topics through the DDS bridge, the cross-distro pointcloud rate
    matches the Humble publisher, type-hash warnings stay below threshold,
    the TF tree is healthy, and the Humble container is publish-only
    (does not subscribe to Jazzy-side topics).

Usage:
    ./cross_distro_check.py

Deps:
    - python3 stdlib only
    - docker (with containers `robot` and `ros2_realsense_isaac` Up)

Env vars:
    JAZZY_CONTAINER  (default: robot)
    ISAAC_CONTAINER  (default: ros2_realsense_isaac)
    HZ_TIMEOUT       (default: 15) — seconds for ros2 topic hz sample
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Tuple

JAZZY_CONTAINER = os.environ.get("JAZZY_CONTAINER", "robot")
ISAAC_CONTAINER = os.environ.get("ISAAC_CONTAINER", "ros2_realsense_isaac")
HZ_TIMEOUT = int(os.environ.get("HZ_TIMEOUT", "15"))
HUMBLE_RATE_FILE = Path("/tmp/humble_pointcloud_rate.txt")

EXPECTED_CAMERA_TOPICS: List[str] = [
    "/camera/color/image_raw",
    "/camera/depth/image_rect_raw",
    "/camera/infra1/image_rect_raw",
    "/camera/infra2/image_rect_raw",
    "/camera/accel/sample",
    "/camera/gyro/sample",
    "/camera/imu/data",
    "/camera/depth/points",
]


# ---- ANSI colors ----
def _supports_color() -> bool:
    return sys.stdout.isatty()


_C = {
    "red": "\033[0;31m" if _supports_color() else "",
    "green": "\033[0;32m" if _supports_color() else "",
    "yellow": "\033[0;33m" if _supports_color() else "",
    "blue": "\033[0;34m" if _supports_color() else "",
    "reset": "\033[0m" if _supports_color() else "",
}


def log_info(msg: str) -> None:
    print(f"{_C['blue']}[INFO]{_C['reset']}  {msg}", flush=True)


def log_pass(msg: str) -> None:
    print(f"{_C['green']}[PASS]{_C['reset']}  {msg}", flush=True)


def log_fail(msg: str) -> None:
    print(f"{_C['red']}[FAIL]{_C['reset']}  {msg}", flush=True)


def log_warn(msg: str) -> None:
    print(f"{_C['yellow']}[WARN]{_C['reset']}  {msg}", flush=True)


Results: List[Tuple[str, str, str, str]] = []  # (name, verdict, value, note)


def record(name: str, verdict: str, value: str, note: str = "") -> None:
    Results.append((name, verdict, value, note))


def run_docker_exec(
    container: str, command: str, timeout: int = 30
) -> subprocess.CompletedProcess:
    cmd = ["docker", "exec", container, "bash", "-c", command]
    return subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=timeout)


# ---- Step (a): Jazzy sees camera topics ----
def check_topic_visibility() -> List[str]:
    log_info(f"Step (a) — Jazzy ({JAZZY_CONTAINER}) topic visibility...")
    result = run_docker_exec(
        JAZZY_CONTAINER,
        "source /opt/ros/jazzy/setup.bash && ros2 topic list",
        timeout=20,
    )
    if result.returncode != 0:
        log_fail(f"ros2 topic list failed: {result.stderr.strip()}")
        record("topic_visibility", "FAIL", "exec failed", result.stderr.strip()[:120])
        return []

    visible = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    camera_topics_visible = [t for t in visible if t.startswith("/camera")]
    missing = [t for t in EXPECTED_CAMERA_TOPICS if t not in visible]

    if not missing:
        log_pass(f"All {len(EXPECTED_CAMERA_TOPICS)} expected camera topics visible cross-distro")
        record("topic_visibility", "PASS",
               f"{len(EXPECTED_CAMERA_TOPICS)}/{len(EXPECTED_CAMERA_TOPICS)}", "")
    else:
        log_fail(f"Missing cross-distro topics: {missing}")
        record("topic_visibility", "FAIL",
               f"{len(EXPECTED_CAMERA_TOPICS) - len(missing)}/{len(EXPECTED_CAMERA_TOPICS)}",
               f"missing: {','.join(missing)}")
    log_info(f"  (camera-* visible: {len(camera_topics_visible)} total)")
    return visible


# ---- Step (b): cross-distro pointcloud rate ----
def parse_avg_rate(output: str) -> float:
    last = 0.0
    for line in output.splitlines():
        m = re.search(r"average rate:\s*([0-9.]+)", line)
        if m:
            last = float(m.group(1))
    return last


def check_pointcloud_rate() -> None:
    log_info("Step (b) — Cross-distro /camera/depth/points rate (Jazzy side)...")
    result = run_docker_exec(
        JAZZY_CONTAINER,
        f"source /opt/ros/jazzy/setup.bash && "
        f"timeout {HZ_TIMEOUT} ros2 topic hz /camera/depth/points 2>&1 || true",
        timeout=HZ_TIMEOUT + 10,
    )
    jazzy_rate = parse_avg_rate(result.stdout)

    humble_rate: float | None = None
    if HUMBLE_RATE_FILE.exists():
        try:
            humble_rate = float(HUMBLE_RATE_FILE.read_text().strip())
        except ValueError:
            humble_rate = None

    if jazzy_rate <= 0:
        log_fail("No /camera/depth/points messages received Jazzy-side")
        record("pointcloud_cross_distro", "FAIL", "0 Hz", "no messages")
        return

    note = ""
    verdict = "PASS"
    if humble_rate is not None and humble_rate > 0:
        diff_pct = abs(jazzy_rate - humble_rate) / humble_rate * 100.0
        note = f"Humble={humble_rate:.2f}, Jazzy={jazzy_rate:.2f}, diff={diff_pct:.1f}%"
        if diff_pct > 20.0:
            verdict = "WARN"
            log_warn(f"Cross-distro pointcloud rate gap >20%: {note}")
        else:
            log_pass(f"Cross-distro rate match: {note}")
    else:
        note = "humble baseline absent"
        log_warn(
            "Humble-side reference rate missing "
            f"({HUMBLE_RATE_FILE}); reporting Jazzy-side rate only"
        )
    record("pointcloud_cross_distro", verdict, f"{jazzy_rate:.2f} Hz", note)


# ---- Step (c): type-hash warnings ----
def check_type_hash_warnings() -> None:
    log_info("Step (c) — Type-hash warning count in robot logs (last 10 min)...")
    result = subprocess.run(
        ["docker", "logs", JAZZY_CONTAINER, "--since", "10m"],
        capture_output=True, text=True, check=False, timeout=20,
    )
    combined = (result.stdout or "") + (result.stderr or "")
    count = sum(1 for ln in combined.splitlines() if "type hash" in ln.lower())

    if count < 100:
        log_pass(f"Type-hash warnings: {count}/10min (<100)")
        record("type_hash_warnings", "PASS", f"{count}/10min", "<100 threshold")
    else:
        log_fail(f"Type-hash warnings exceed threshold: {count}/10min")
        record("type_hash_warnings", "FAIL", f"{count}/10min", "exceeds 100")


# ---- Step (d): TF tree check ----
def check_tf_tree() -> None:
    log_info("Step (d) — TF tree health (view_frames in Jazzy)...")
    result = run_docker_exec(
        JAZZY_CONTAINER,
        "source /opt/ros/jazzy/setup.bash && "
        "cd /tmp && ros2 run tf2_tools view_frames",
        timeout=30,
    )
    if result.returncode == 0:
        log_pass("view_frames exited 0")
        record("tf_tree", "PASS", "exit 0", "")
    else:
        log_fail(f"view_frames exit {result.returncode}: {result.stderr.strip()[:120]}")
        record("tf_tree", "FAIL",
               f"exit {result.returncode}", result.stderr.strip()[:120])


# ---- Step (e): Humble container is publish-only ----
def find_isaac_node() -> str | None:
    result = run_docker_exec(
        ISAAC_CONTAINER,
        "source /opt/ros/humble/setup.bash && ros2 node list",
        timeout=20,
    )
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        line = line.strip()
        if "realsense" in line or "isaac" in line:
            return line
    return None


def parse_node_subscribers(output: str) -> List[str]:
    """Parse ros2 node info; return topic names under 'Subscribers:'."""
    subs: List[str] = []
    in_subs = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("Subscribers:"):
            in_subs = True
            continue
        if in_subs:
            # next major section header ends the subscribers block
            if stripped.endswith(":") and not stripped.startswith("/"):
                break
            m = re.match(r"^(/\S+):", stripped)
            if m:
                subs.append(m.group(1))
            elif stripped == "":
                continue
    return subs


def check_publish_only() -> None:
    log_info("Step (e) — Humble container publish-only check...")
    candidate = find_isaac_node()
    node_to_inspect = candidate or "/isaac_realsense_container"
    log_info(f"  Inspecting node: {node_to_inspect}")
    result = run_docker_exec(
        ISAAC_CONTAINER,
        f"source /opt/ros/humble/setup.bash && ros2 node info {node_to_inspect}",
        timeout=20,
    )
    if result.returncode != 0:
        log_warn(f"ros2 node info failed for {node_to_inspect}: "
                 f"{result.stderr.strip()[:120]}")
        record("publish_only", "WARN",
               "node_info failed",
               f"node={node_to_inspect}; {result.stderr.strip()[:120]}")
        return

    subs = parse_node_subscribers(result.stdout)
    # Tolerate parameter_events / clock as benign subscriptions
    benign = {"/parameter_events", "/clock", "/rosout"}
    non_benign = [s for s in subs if s not in benign]

    if not non_benign:
        log_pass(f"Node has no non-benign subscribers ({len(subs)} total, all benign)")
        record("publish_only", "PASS", f"{len(subs)} subs (all benign)", "")
    else:
        log_fail(f"Node subscribes to: {non_benign}")
        record("publish_only", "FAIL", f"{len(non_benign)} non-benign subs",
               ",".join(non_benign))


# ---- Summary ----
def print_summary() -> int:
    print("")
    print("===============================================================")
    print(" ISAAC HUMBLE CROSS-DISTRO CHECK — H7 SUMMARY")
    print("===============================================================")
    print(f"{'TEST':<28} {'VERDICT':<6} {'VALUE':<36} NOTE")
    print("---------------------------------------------------------------")
    pass_count = fail_count = warn_count = 0
    for name, verdict, value, note in Results:
        if verdict == "PASS":
            color = _C["green"]
            pass_count += 1
        elif verdict == "FAIL":
            color = _C["red"]
            fail_count += 1
        else:
            color = _C["yellow"]
            warn_count += 1
        print(f"{name:<28} {color}{verdict:<6}{_C['reset']} {value:<36} {note}")
    print("---------------------------------------------------------------")
    print(f" TOTAL: {pass_count} PASS, {warn_count} WARN, {fail_count} FAIL")
    print("===============================================================")
    return 0 if fail_count == 0 else 1


def main() -> int:
    log_info(f"H7 cross-distro check — Jazzy={JAZZY_CONTAINER}, Humble={ISAAC_CONTAINER}")
    log_info(f"Started @ {time.strftime('%Y-%m-%d %H:%M:%S')}")
    try:
        check_topic_visibility()
    except Exception as e:
        log_fail(f"topic_visibility crashed: {e}")
        record("topic_visibility", "FAIL", "exception", str(e)[:120])
    try:
        check_pointcloud_rate()
    except Exception as e:
        log_fail(f"pointcloud_cross_distro crashed: {e}")
        record("pointcloud_cross_distro", "FAIL", "exception", str(e)[:120])
    try:
        check_type_hash_warnings()
    except Exception as e:
        log_fail(f"type_hash_warnings crashed: {e}")
        record("type_hash_warnings", "FAIL", "exception", str(e)[:120])
    try:
        check_tf_tree()
    except Exception as e:
        log_fail(f"tf_tree crashed: {e}")
        record("tf_tree", "FAIL", "exception", str(e)[:120])
    try:
        check_publish_only()
    except Exception as e:
        log_fail(f"publish_only crashed: {e}")
        record("publish_only", "FAIL", "exception", str(e)[:120])
    return print_summary()


if __name__ == "__main__":
    sys.exit(main())
