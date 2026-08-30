#!/usr/bin/env python3
"""Summarize the machine-readable host contention sampler CSV."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def stats(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "mean": None, "p50": None, "p95": None, "p99": None, "max": None}
    return {
        "count": len(values),
        "mean": sum(values) / len(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "max": max(values),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()

    with args.csv.open(newline="") as handle:
        rows = list(csv.DictReader(row for row in handle if not row.startswith("#")))

    columns = ["sidescreen_cpu_pct", "windowserver_cpu_pct", "total_cpu_pct", "memory_free_pct", "swap_used_mb"]
    summaries: dict[str, object] = {}
    for column in columns:
        values: list[float] = []
        for row in rows:
            try:
                value = float(row.get(column, "nan"))
            except ValueError:
                continue
            if math.isfinite(value):
                values.append(value)
        summaries[column] = stats(values)

    report = {
        "rows": len(rows),
        "scenario": rows[0].get("scenario") if rows else None,
        "metrics": summaries,
    }
    args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    def value(column: str, key: str) -> object:
        return summaries[column][key]  # type: ignore[index]

    markdown = "\n".join([
        "# Tablet Bridge host-load report",
        "",
        f"- Scenario: `{report['scenario']}`",
        f"- Samples: {report['rows']}",
        "",
        "| Metric | mean | p50 | p95 | p99 | max |",
        "|---|---:|---:|---:|---:|---:|",
        f"| Tablet Bridge CPU % | {value('sidescreen_cpu_pct', 'mean')} | {value('sidescreen_cpu_pct', 'p50')} | {value('sidescreen_cpu_pct', 'p95')} | {value('sidescreen_cpu_pct', 'p99')} | {value('sidescreen_cpu_pct', 'max')} |",
        f"| WindowServer CPU % | {value('windowserver_cpu_pct', 'mean')} | {value('windowserver_cpu_pct', 'p50')} | {value('windowserver_cpu_pct', 'p95')} | {value('windowserver_cpu_pct', 'p99')} | {value('windowserver_cpu_pct', 'max')} |",
        f"| Total CPU % | {value('total_cpu_pct', 'mean')} | {value('total_cpu_pct', 'p50')} | {value('total_cpu_pct', 'p95')} | {value('total_cpu_pct', 'p99')} | {value('total_cpu_pct', 'max')} |",
        f"| Memory free % | {value('memory_free_pct', 'mean')} | {value('memory_free_pct', 'p50')} | {value('memory_free_pct', 'p95')} | {value('memory_free_pct', 'p99')} | {value('memory_free_pct', 'max')} |",
        f"| Swap used MB | {value('swap_used_mb', 'mean')} | {value('swap_used_mb', 'p50')} | {value('swap_used_mb', 'p95')} | {value('swap_used_mb', 'p99')} | {value('swap_used_mb', 'max')} |",
        "",
        "CPU values are the macOS `ps` process percentages; memory and swap are host snapshots, not app-owned allocations.",
        "",
    ])
    args.markdown.write_text(markdown)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
