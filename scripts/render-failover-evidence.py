#!/usr/bin/env python3
"""Render the recorded failover CSV as a reviewable evidence plot."""

from __future__ import annotations

import csv
import sys
from datetime import datetime
from pathlib import Path

import matplotlib.pyplot as plt


EXPECTED_COLUMNS = [
    "timestamp",
    "http_status",
    "latency_ms",
    "serving_region",
    "serving_cluster",
    "correlation_id",
]


def read_summary(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "evidence/09-failover.csv"
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else repo / "evidence/09-failover.png"
    summary_path = repo / "evidence/10-backend-health-after.txt"

    with csv_path.open(encoding="utf-8", newline="") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != EXPECTED_COLUMNS:
            raise ValueError("failover CSV columns do not match the frozen schema")
        rows = list(reader)
    if not rows:
        raise ValueError("failover CSV has no requests")

    timestamps = [datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")) for row in rows]
    if timestamps != sorted(timestamps):
        raise ValueError("failover CSV is not chronological")
    start = timestamps[0]
    seconds = [(timestamp - start).total_seconds() for timestamp in timestamps]
    statuses = [int(row["http_status"]) for row in rows]
    latencies = [int(row["latency_ms"]) for row in rows]
    summary = read_summary(summary_path)

    colors = {
        "us-central1": "#1f77b4",
        "us-east4": "#2ca02c",
        "failure": "#c62828",
    }
    point_colors = [
        colors.get(row["serving_region"], colors["failure"]) for row in rows
    ]
    failures = [index for index, status in enumerate(statuses) if status != 200]

    figure, (status_axis, latency_axis) = plt.subplots(
        2, 1, figsize=(16, 9), sharex=True, gridspec_kw={"height_ratios": [1, 2]}
    )
    figure.suptitle(
        "Regional GKE failover — recorded public requests",
        fontsize=18,
        fontweight="bold",
    )
    figure.text(
        0.5,
        0.925,
        (
            f"{len(rows)} requests · {len(failures)} transition failures · "
            f"LB drain {summary.get('load_balancer_drain_seconds', '?')}s · "
            f"LB recovery {summary.get('load_balancer_recovery_seconds', '?')}s"
        ),
        ha="center",
        fontsize=11,
    )

    if failures:
        start_failure = seconds[failures[0]]
        end_failure = seconds[failures[-1]]
        for axis in (status_axis, latency_axis):
            axis.axvspan(
                start_failure,
                end_failure,
                color=colors["failure"],
                alpha=0.10,
                label="failed-request window" if axis is status_axis else None,
            )

    status_axis.scatter(seconds, statuses, c=point_colors, s=22, marker="o")
    status_axis.set_yticks([200, 503])
    status_axis.set_ylabel("HTTP status")
    status_axis.grid(axis="both", alpha=0.25)

    for region in ("us-central1", "us-east4"):
        region_indexes = [
            index for index, row in enumerate(rows) if row["serving_region"] == region
        ]
        latency_axis.scatter(
            [seconds[index] for index in region_indexes],
            [latencies[index] for index in region_indexes],
            color=colors[region],
            s=24,
            label=region,
        )
    if failures:
        latency_axis.scatter(
            [seconds[index] for index in failures],
            [latencies[index] for index in failures],
            color=colors["failure"],
            marker="x",
            s=42,
            label="non-200",
        )

    latency_axis.set_xlabel("Seconds from first recorded request")
    latency_axis.set_ylabel("Latency (ms)")
    latency_axis.grid(axis="both", alpha=0.25)
    latency_axis.legend(loc="upper right", frameon=False)
    status_axis.legend(loc="upper right", frameon=False)
    figure.text(
        0.01,
        0.012,
        (
            f"Fault: {summary.get('fault_target', '?')}   "
            f"Survivor: {summary.get('surviving_cell', '?')}   "
            f"Image: {summary.get('image_sha', '?')}"
        ),
        fontsize=9,
    )
    figure.tight_layout(rect=(0, 0.04, 1, 0.90))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output_path, dpi=120, metadata={"Software": "matplotlib"})
    plt.close(figure)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
