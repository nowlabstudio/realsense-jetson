#!/usr/bin/env python3
"""freeze_detector_isaac.py — H8 24h burn-in freeze watchdog.

Purpose:
    Continuously monitor the Isaac Humble RealSense container for
    silent freezes and container restarts. Every interval:
      * Records `docker inspect ... RestartCount` and reports CRITICAL on delta
      * Calls `ros2 topic echo --once --timeout N /camera/depth/points`
        to confirm fresh messages; logs WARNING when no message arrives

Output: append-only JSONL with one event per check, plus CRITICAL/WARNING
events when anomalies are detected.

Usage:
    ./freeze_detector_isaac.py [--container ros2_realsense_isaac]
                               [--interval 30]
                               [--log /tmp/isaac_freeze_log_<YYYYMMDD>.jsonl]

Deps: python3 stdlib only.
Env vars: none required (all configurable via flags).
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import TextIO


_SHUTDOWN = False


def _supports_color() -> bool:
    return sys.stdout.isatty()


_C = {
    "red": "\033[0;31m" if _supports_color() else "",
    "green": "\033[0;32m" if _supports_color() else "",
    "yellow": "\033[0;33m" if _supports_color() else "",
    "blue": "\033[0;34m" if _supports_color() else "",
    "reset": "\033[0m" if _supports_color() else "",
}


def log_console(event_type: str, message: str) -> None:
    color = {
        "status": _C["blue"],
        "warning": _C["yellow"],
        "critical": _C["red"],
        "summary": _C["green"],
    }.get(event_type, "")
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {color}{event_type.upper():<8}{_C['reset']} {message}", flush=True)


def get_restart_count(container: str) -> int | None:
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{.RestartCount}}", container],
        capture_output=True, text=True, check=False, timeout=10,
    )
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def probe_pointcloud(container: str, exec_timeout: int) -> tuple[bool, float]:
    """Return (success, elapsed_sec)."""
    cmd = [
        "docker", "exec", container, "bash", "-c",
        "source /opt/ros/humble/setup.bash && "
        f"timeout {exec_timeout} ros2 topic echo --once --timeout {exec_timeout} "
        "/camera/depth/points >/dev/null 2>&1",
    ]
    t0 = time.monotonic()
    try:
        result = subprocess.run(cmd, check=False, timeout=exec_timeout + 5)
        elapsed = time.monotonic() - t0
        return (result.returncode == 0), elapsed
    except subprocess.TimeoutExpired:
        return False, time.monotonic() - t0


def write_event(fp: TextIO, event: dict) -> None:
    fp.write(json.dumps(event) + "\n")
    fp.flush()


def _signal_handler(signum, frame):  # type: ignore[no-untyped-def]
    global _SHUTDOWN
    _SHUTDOWN = True


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--container", default="ros2_realsense_isaac",
                   help="Target docker container name")
    p.add_argument("--interval", type=int, default=30,
                   help="Polling interval in seconds")
    default_log = f"/tmp/isaac_freeze_log_{datetime.now().strftime('%Y%m%d')}.jsonl"
    p.add_argument("--log", default=default_log,
                   help="JSONL log output path")
    p.add_argument("--echo-timeout", type=int, default=3,
                   help="Per-probe ros2 topic echo timeout (seconds)")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    log_console("status", f"freeze_detector_isaac starting "
                          f"container={args.container} interval={args.interval}s "
                          f"log={log_path}")

    # Baseline restart count
    baseline_restart = get_restart_count(args.container)
    if baseline_restart is None:
        log_console("critical",
                    f"Could not read RestartCount for {args.container} — exiting")
        return 2

    last_known_restart = baseline_restart

    # Stats
    total_checks = 0
    warning_count = 0
    critical_count = 0
    last_success_ts: float | None = None
    start_ts = time.time()

    fp = log_path.open("a", buffering=1)
    # Write a start event
    write_event(fp, {
        "ts": datetime.now().isoformat(timespec="seconds"),
        "event_type": "status",
        "message": "freeze_detector_isaac started",
        "container": args.container,
        "interval_sec": args.interval,
        "baseline_restart_count": baseline_restart,
    })

    try:
        while not _SHUTDOWN:
            cycle_start = time.monotonic()
            total_checks += 1
            now_iso = datetime.now().isoformat(timespec="seconds")

            # Restart count check
            current_restart = get_restart_count(args.container)
            if current_restart is None:
                msg = f"docker inspect failed for {args.container}"
                log_console("critical", msg)
                write_event(fp, {
                    "ts": now_iso,
                    "event_type": "critical",
                    "message": msg,
                    "restart_count": None,
                    "last_msg_age_sec": None,
                })
                critical_count += 1
            else:
                if current_restart > last_known_restart:
                    msg = (f"Container restart detected: "
                           f"{last_known_restart} -> {current_restart}")
                    log_console("critical", msg)
                    write_event(fp, {
                        "ts": now_iso,
                        "event_type": "critical",
                        "message": msg,
                        "restart_count_old": last_known_restart,
                        "restart_count_new": current_restart,
                        "restart_count": current_restart,
                    })
                    critical_count += 1
                    last_known_restart = current_restart

            # Probe pointcloud freshness
            ok, elapsed = probe_pointcloud(args.container, args.echo_timeout)
            if ok:
                last_success_ts = time.time()
                last_msg_age_sec = 0.0
                write_event(fp, {
                    "ts": now_iso,
                    "event_type": "status",
                    "message": "depth/points fresh",
                    "restart_count": current_restart,
                    "last_msg_age_sec": last_msg_age_sec,
                    "probe_elapsed_sec": round(elapsed, 3),
                })
            else:
                if last_success_ts is None:
                    last_msg_age_sec = time.time() - start_ts
                else:
                    last_msg_age_sec = time.time() - last_success_ts
                msg = (f"No /camera/depth/points msg within "
                       f"{args.echo_timeout}s (age={last_msg_age_sec:.1f}s)")
                log_console("warning", msg)
                write_event(fp, {
                    "ts": now_iso,
                    "event_type": "warning",
                    "message": msg,
                    "restart_count": current_restart,
                    "last_msg_age_sec": round(last_msg_age_sec, 1),
                    "probe_elapsed_sec": round(elapsed, 3),
                })
                warning_count += 1

            # Sleep until next interval (account for probe time)
            elapsed_cycle = time.monotonic() - cycle_start
            sleep_for = max(0.0, args.interval - elapsed_cycle)
            # Interruptible sleep in 0.5s slices
            slept = 0.0
            while slept < sleep_for and not _SHUTDOWN:
                step = min(0.5, sleep_for - slept)
                time.sleep(step)
                slept += step

    finally:
        # Graceful summary
        end_ts = time.time()
        duration = end_ts - start_ts
        summary = {
            "ts": datetime.now().isoformat(timespec="seconds"),
            "event_type": "summary",
            "duration_sec": round(duration, 1),
            "total_checks": total_checks,
            "warning_count": warning_count,
            "critical_count": critical_count,
            "baseline_restart_count": baseline_restart,
            "final_restart_count": last_known_restart,
            "restart_delta": last_known_restart - baseline_restart
                              if isinstance(last_known_restart, int) else None,
        }
        write_event(fp, summary)
        fp.close()

        log_console("summary", "=" * 50)
        log_console("summary", f"Duration:       {duration:.1f}s")
        log_console("summary", f"Total checks:   {total_checks}")
        log_console("summary", f"Warnings:       {warning_count}")
        log_console("summary", f"Critical:       {critical_count}")
        log_console("summary",
                    f"Restart delta:  {last_known_restart - baseline_restart}")
        log_console("summary", f"Log file:       {log_path}")
        log_console("summary", "=" * 50)

    return 0 if critical_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
