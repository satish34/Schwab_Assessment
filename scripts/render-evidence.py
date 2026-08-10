#!/usr/bin/env python3
"""Render honest evidence views from validated CLI and BigQuery outputs."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt


PROJECT = "schwab-assessment-gke"
REGION_CLUSTER = {
    "us-central1": "gke-risk-usc1",
    "us-east4": "gke-risk-use4",
}
SERVICES = {"app-a-gateway", "app-b-engine"}
DECISIONS = {"RATES_RETURNED"}
UUID_RE = re.compile(r"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$")
TRACE_RE = re.compile(r"^[0-9a-f]{32}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
MINUTE_FORMAT = "%Y-%m-%d %H:%M:%S"
SCHEMAS = {
    "error-rate": ["error_count", "error_rate_pct", "minute", "request_count"],
    "latency": ["minute", "p50_ms", "p95_ms", "p99_ms"],
    "trace-join": [
        "app_a_latency_ms", "app_a_status", "app_a_timestamp",
        "app_b_latency_ms", "app_b_status", "app_b_timestamp", "cluster",
        "correlation_id", "region", "trace_id",
    ],
    "regional-traffic": [
        "cluster", "decision", "minute", "region", "request_count", "service",
    ],
}
CSV_NAMES = {
    "error-rate": "07-bigquery-error-rate.csv",
    "latency": "07-bigquery-latency-percentiles.csv",
    "trace-join": "07-bigquery-trace-join.csv",
    "regional-traffic": "07-bigquery-regional-traffic.csv",
}
JSON_NAMES = {
    "error-rate": "01_error_rate.json",
    "latency": "02_latency_percentiles.json",
    "trace-join": "03_trace_join.json",
    "regional-traffic": "04_regional_traffic.json",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def integer(value: Any, field: str, minimum: int = 0) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be an integer") from exc
    require(parsed >= minimum, f"{field} must be >= {minimum}")
    return parsed


def number(value: Any, field: str, minimum: float = 0) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be numeric") from exc
    require(parsed >= minimum, f"{field} must be >= {minimum}")
    return parsed


def minute(value: Any, field: str = "minute") -> datetime:
    try:
        return datetime.strptime(str(value), MINUTE_FORMAT)
    except ValueError as exc:
        raise ValueError(f"{field} must use {MINUTE_FORMAT}") from exc


def validate_rows(kind: str, rows: list[dict[str, Any]]) -> None:
    expected = set(SCHEMAS[kind])
    require(rows, f"{kind} must contain at least one row")
    for index, row in enumerate(rows):
        require(set(row) == expected, f"{kind} row {index} has an unexpected schema")
        if kind == "error-rate":
            requests = integer(row["request_count"], "request_count", 1)
            errors = integer(row["error_count"], "error_count")
            rate = number(row["error_rate_pct"], "error_rate_pct")
            minute(row["minute"])
            require(errors <= requests, "error_count exceeds request_count")
            require(rate <= 100, "error_rate_pct exceeds 100")
        elif kind == "latency":
            p50 = number(row["p50_ms"], "p50_ms")
            p95 = number(row["p95_ms"], "p95_ms")
            p99 = number(row["p99_ms"], "p99_ms")
            minute(row["minute"])
            require(p50 <= p95 <= p99, "latency percentiles are unordered")
        elif kind == "trace-join":
            require(row["region"] in REGION_CLUSTER, "unexpected trace region")
            require(row["cluster"] == REGION_CLUSTER[row["region"]], "trace cell mismatch")
            require(UUID_RE.fullmatch(str(row["correlation_id"])) is not None,
                    "invalid trace correlation_id")
            require(TRACE_RE.fullmatch(str(row["trace_id"])) is not None,
                    "invalid trace_id")
            for field in ("app_a_timestamp", "app_b_timestamp"):
                minute(row[field], field)
            for field in ("app_a_status", "app_b_status"):
                status = integer(row[field], field, 100)
                require(status < 600, f"{field} must be an HTTP status")
            number(row["app_a_latency_ms"], "app_a_latency_ms")
            number(row["app_b_latency_ms"], "app_b_latency_ms")
        else:
            require(row["region"] in REGION_CLUSTER, "unexpected traffic region")
            require(row["cluster"] == REGION_CLUSTER[row["region"]], "traffic cell mismatch")
            require(row["service"] in SERVICES, "unexpected traffic service")
            require(row["decision"] in DECISIONS, "unexpected decision")
            integer(row["request_count"], "request_count", 1)
            minute(row["minute"])

    if kind in {"trace-join", "regional-traffic"}:
        require({row["region"] for row in rows} == set(REGION_CLUSTER),
                f"{kind} must contain both regions")
    if kind == "regional-traffic":
        require({row["service"] for row in rows} == SERVICES,
                "regional traffic must contain both services")
        require({row["decision"] for row in rows} == DECISIONS,
                "regional traffic must contain the exchange-rate outcome")


def load_json_rows(path: Path, kind: str) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(data, list) and all(isinstance(row, dict) for row in data),
            f"{path} must contain a JSON array of objects")
    validate_rows(kind, data)
    return data


def load_csv_rows(path: Path, kind: str) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        require(reader.fieldnames == SCHEMAS[kind], f"{path} has an unexpected header")
        rows = list(reader)
    validate_rows(kind, rows)
    return rows


def export_bigquery(args: argparse.Namespace) -> None:
    source_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    for kind, json_name in JSON_NAMES.items():
        rows = load_json_rows(source_dir / json_name, kind)
        output = output_dir / CSV_NAMES[kind]
        with output.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=SCHEMAS[kind], lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)


def finish_figure(fig: plt.Figure, output: Path, title: str, source: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(
        output,
        dpi=160,
        facecolor="white",
        bbox_inches="tight",
        metadata={
            "Title": title,
            "Description": "Generated from validated live evidence; not a Console screenshot.",
            "Source": source,
        },
    )
    plt.close(fig)
    require(output.stat().st_size >= 10_000, f"rendered PNG is unexpectedly small: {output}")


def render_budget(args: argparse.Namespace) -> None:
    path = Path(args.input)
    pairs: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        require("=" in line, "budget evidence contains a malformed line")
        key, value = line.split("=", 1)
        require(key not in pairs, f"duplicate budget field: {key}")
        pairs[key] = value
    require(set(pairs) == {"project", "amount_usd", "spend_basis", "thresholds"},
            "budget evidence schema changed")
    require(pairs["project"] == PROJECT, "budget project mismatch")
    require(pairs["amount_usd"] == "30", "budget amount must be USD 30")
    require(pairs["spend_basis"] == "CURRENT_SPEND", "budget spend basis mismatch")
    thresholds = [int(value.rstrip("%")) for value in pairs["thresholds"].split(",")]
    require(thresholds == [50, 80, 90, 100], "budget thresholds changed")

    fig, ax = plt.subplots(figsize=(11, 5.5))
    ax.set_xlim(-0.5, 30.5)
    ax.set_ylim(-0.6, 0.8)
    ax.hlines(0, 0, 30, color="#34495e", linewidth=8)
    colors = ["#3498db", "#f1c40f", "#e67e22", "#c0392b"]
    for threshold, color in zip(thresholds, colors):
        dollars = 30 * threshold / 100
        ax.scatter(dollars, 0, s=260, color=color, zorder=3)
        ax.text(dollars, 0.22, f"{threshold}%\n${dollars:g}", ha="center", weight="bold")
    ax.text(0, -0.35, "$0", ha="center")
    ax.text(30, -0.35, "$30 monthly safety budget", ha="right", weight="bold")
    ax.set_title("Assessment budget and alert thresholds", fontsize=20, weight="bold", pad=22)
    ax.text(0.5, 0.94, PROJECT, transform=ax.transAxes, ha="center", fontsize=12)
    ax.text(0.5, 0.02, "Alert thresholds only — this chart does not claim current spend",
            transform=ax.transAxes, ha="center", color="#555555")
    ax.axis("off")
    fig.text(0.5, 0.01,
             "Generated from validated live gcloud budget evidence • not a Console screenshot",
             ha="center", fontsize=9, color="#666666")
    finish_figure(
        fig, Path(args.output), "Assessment budget evidence", "evidence/01-budget.txt"
    )


def render_logging(args: argparse.Namespace) -> None:
    path = Path(args.input)
    rows = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(rows, list) and len(rows) == 2, "logging evidence must contain two rows")
    required = {
        "service", "service_version", "region", "cluster", "correlation_id", "trace_id",
        "status_code", "decision", "latency_ms", "downstream_latency_ms",
    }
    require(all(isinstance(row, dict) and set(row) == required for row in rows),
            "logging evidence schema changed")
    require({row["service"] for row in rows} == SERVICES, "logging evidence needs both services")
    require(len({row["service_version"] for row in rows}) == 1 and
            SHA_RE.fullmatch(rows[0]["service_version"]) is not None, "logging SHA mismatch")
    for field, pattern in (("correlation_id", UUID_RE), ("trace_id", TRACE_RE)):
        require(len({row[field] for row in rows}) == 1 and pattern.fullmatch(rows[0][field]),
                f"logging {field} mismatch")
    require(len({(row["region"], row["cluster"]) for row in rows}) == 1,
            "logging rows are not from one cell")
    region = rows[0]["region"]
    require(region in REGION_CLUSTER and rows[0]["cluster"] == REGION_CLUSTER[region],
            "logging cell mismatch")
    for row in rows:
        require(integer(row["status_code"], "status_code", 100) == 200,
                "logging evidence is not a successful pair")
        require(row["decision"] in DECISIONS, "logging decision invalid")
        number(row["latency_ms"], "latency_ms")
        number(row["downstream_latency_ms"], "downstream_latency_ms")

    rows.sort(key=lambda row: row["service"])
    table_rows = [[
        row["service"], row["region"], row["cluster"], str(row["status_code"]),
        row["decision"], str(row["latency_ms"]), str(row["downstream_latency_ms"]),
    ] for row in rows]
    fig, ax = plt.subplots(figsize=(13, 5.8))
    ax.axis("off")
    ax.set_title("Same-trace Java → .NET structured logging evidence",
                 fontsize=19, weight="bold", pad=30)
    ax.text(0.5, 0.94, f"correlation_id  {rows[0]['correlation_id']}",
            transform=ax.transAxes, ha="center", family="monospace")
    ax.text(0.5, 0.89, f"trace_id        {rows[0]['trace_id']}",
            transform=ax.transAxes, ha="center", family="monospace")
    table = ax.table(
        cellText=table_rows,
        colLabels=["Service", "Region", "Cluster", "HTTP", "Result", "Latency ms", "Downstream ms"],
        cellLoc="center", loc="center", colColours=["#dfeaf4"] * 7,
    )
    table.auto_set_font_size(False)
    table.set_fontsize(10)
    table.scale(1, 2.1)
    ax.text(0.5, 0.12, f"Immutable image SHA: {rows[0]['service_version']}",
            transform=ax.transAxes, ha="center", family="monospace", fontsize=9)
    fig.text(0.5, 0.01,
             "Generated from validated live Cloud Logging CLI evidence • not a Console screenshot",
             ha="center", fontsize=9, color="#666666")
    finish_figure(
        fig, Path(args.output), "Structured logging evidence", "evidence/06-logging.txt"
    )


def render_bigquery(args: argparse.Namespace) -> None:
    paths = {
        "error-rate": Path(args.error_rate),
        "latency": Path(args.latency),
        "trace-join": Path(args.trace_join),
        "regional-traffic": Path(args.regional_traffic),
    }
    data = {kind: load_csv_rows(path, kind) for kind, path in paths.items()}
    errors = sorted(data["error-rate"], key=lambda row: minute(row["minute"]))
    latency = sorted(data["latency"], key=lambda row: minute(row["minute"]))
    traces = data["trace-join"]
    traffic = data["regional-traffic"]

    fig, axes = plt.subplots(2, 2, figsize=(15, 9))
    fig.suptitle("Validated BigQuery application evidence", fontsize=21, weight="bold")

    ax = axes[0, 0]
    times = [minute(row["minute"]) for row in errors]
    ax.bar(times, [integer(row["request_count"], "request_count") for row in errors],
           width=0.0007, color="#4c78a8", label="Requests")
    rate_axis = ax.twinx()
    rate_axis.plot(times, [number(row["error_rate_pct"], "error_rate_pct") for row in errors],
                   color="#c0392b", marker="o", label="Error rate %")
    ax.set_title("App A requests and error rate")
    ax.set_ylabel("Requests")
    rate_axis.set_ylabel("Error rate %")
    rate_axis.set_ylim(bottom=0)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))

    ax = axes[0, 1]
    latency_times = [minute(row["minute"]) for row in latency]
    for field, label, color in (
        ("p50_ms", "p50", "#2ca02c"),
        ("p95_ms", "p95", "#ff7f0e"),
        ("p99_ms", "p99", "#d62728"),
    ):
        ax.plot(latency_times, [number(row[field], field) for row in latency],
                label=label, color=color, marker=".")
    ax.set_title("App A latency percentiles")
    ax.set_ylabel("Milliseconds")
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
    ax.legend()

    totals: dict[tuple[str, str], int] = defaultdict(int)
    for row in traffic:
        totals[(row["region"], row["service"])] += integer(row["request_count"], "request_count")
    ax = axes[1, 0]
    regions = list(REGION_CLUSTER)
    app_a = [totals[(region, "app-a-gateway")] for region in regions]
    app_b = [totals[(region, "app-b-engine")] for region in regions]
    positions = range(len(regions))
    ax.bar([pos - 0.18 for pos in positions], app_a, width=0.36,
           label="app-a-gateway", color="#4c78a8")
    ax.bar([pos + 0.18 for pos in positions], app_b, width=0.36,
           label="app-b-engine", color="#72b7b2")
    ax.set_xticks(list(positions), regions)
    ax.set_ylabel("Request log rows")
    ax.set_title("Regional traffic by service")
    ax.legend()

    trace_counts = {region: sum(row["region"] == region for row in traces) for region in regions}
    app_a_medians = {
        region: statistics.median(number(row["app_a_latency_ms"], "app_a_latency_ms")
                                  for row in traces if row["region"] == region)
        for region in regions
    }
    ax = axes[1, 1]
    ax.axis("off")
    ax.set_title("Cross-service trace joins", pad=18)
    lines = [f"Verified joins: {len(traces)}"]
    for region in regions:
        lines.append(
            f"{region}: {trace_counts[region]} joins • median App A {app_a_medians[region]:g} ms"
        )
    lines.extend([
        "", "Every row has matching region/cluster,",
        "valid trace/correlation IDs, and both service statuses.",
    ])
    ax.text(0.5, 0.52, "\n".join(lines), transform=ax.transAxes,
            ha="center", va="center", fontsize=12)

    for axis in (axes[0, 0], axes[0, 1]):
        axis.tick_params(axis="x", rotation=30)
        axis.grid(axis="y", alpha=0.2)
    fig.tight_layout(rect=(0, 0.05, 1, 0.95))
    fig.text(0.5, 0.015,
             "Generated from four validated live BigQuery query CSVs • not a Console screenshot",
             ha="center", fontsize=9, color="#666666")
    finish_figure(
        fig, Path(args.output), "BigQuery application evidence",
        ", ".join(f"evidence/{CSV_NAMES[kind]}" for kind in paths),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    export = commands.add_parser("export-bigquery")
    export.add_argument("--input-dir", required=True)
    export.add_argument("--output-dir", required=True)
    export.set_defaults(func=export_bigquery)

    budget = commands.add_parser("budget")
    budget.add_argument("--input", required=True)
    budget.add_argument("--output", required=True)
    budget.set_defaults(func=render_budget)

    logging = commands.add_parser("logging")
    logging.add_argument("--input", required=True)
    logging.add_argument("--output", required=True)
    logging.set_defaults(func=render_logging)

    bigquery = commands.add_parser("bigquery")
    bigquery.add_argument("--error-rate", required=True)
    bigquery.add_argument("--latency", required=True)
    bigquery.add_argument("--trace-join", required=True)
    bigquery.add_argument("--regional-traffic", required=True)
    bigquery.add_argument("--output", required=True)
    bigquery.set_defaults(func=render_bigquery)

    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
