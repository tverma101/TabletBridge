#!/usr/bin/env python3
"""Analyze an Android Tablet Bridge lab frame-trace CSV.

The input is produced by FrameTraceRecorder and contains Android monotonic
timestamps plus the Mac encoder frame ID. The report intentionally keeps
cadence variance, ID discontinuities, and freshness latency separate from
average FPS.
"""

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


def summary(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "p50_ms": None, "p95_ms": None, "p99_ms": None, "max_ms": None}
    mean = sum(values) / len(values)
    return {
        "count": len(values),
        "p50_ms": percentile(values, 0.50),
        "p95_ms": percentile(values, 0.95),
        "p99_ms": percentile(values, 0.99),
        "max_ms": max(values),
        "mean_ms": mean,
        "stddev_ms": math.sqrt(sum((value - mean) ** 2 for value in values) / len(values)),
        "mad_ms": percentile([abs(value - (percentile(values, 0.50) or 0.0)) for value in values], 0.50),
    }


def load_rows(path: Path) -> list[dict[str, int]]:
    with path.open(newline="") as handle:
        reader = csv.DictReader(row for row in handle if not row.startswith("#"))
        rows: list[dict[str, int]] = []
        for raw in reader:
            try:
                rows.append({key: int(value or 0) for key, value in raw.items()})
            except (TypeError, ValueError):
                continue
        return rows


def analyze(rows: list[dict[str, int]], target_fps: float) -> dict[str, object]:
    rendered = [row for row in rows if row.get("surface_rendered_ns", 0) > 0]
    render_intervals_ms: list[float] = []
    freshness_ms: list[float] = []
    queue_ms: list[float] = []
    duplicate = skipped = reordered = 0
    last_render_ns = 0
    last_frame_id = 0
    for row in rendered:
        rendered_ns = row["surface_rendered_ns"]
        if last_render_ns and rendered_ns > last_render_ns:
            render_intervals_ms.append((rendered_ns - last_render_ns) / 1_000_000.0)
        last_render_ns = max(last_render_ns, rendered_ns)
        capture_ns = row.get("capture_ns", 0)
        if capture_ns > 0 and rendered_ns >= capture_ns:
            freshness_ms.append((rendered_ns - capture_ns) / 1_000_000.0)
        queued_ns = row.get("input_queued_ns", 0)
        release_ns = row.get("output_release_requested_ns", 0)
        if queued_ns > 0 and release_ns >= queued_ns:
            queue_ms.append((release_ns - queued_ns) / 1_000_000.0)
        frame_id = row.get("frame_id", 0)
        if frame_id > 0:
            if last_frame_id:
                if frame_id == last_frame_id:
                    duplicate += 1
                elif frame_id < last_frame_id:
                    reordered += 1
                elif frame_id > last_frame_id + 1:
                    skipped += frame_id - last_frame_id - 1
            if frame_id > last_frame_id:
                last_frame_id = frame_id

    period_ms = 1000.0 / target_fps if target_fps > 0 else 0.0
    lower = period_ms * 0.75
    upper = period_ms * 1.25
    outside_band = sum(1 for value in render_intervals_ms if not lower <= value <= upper)
    interval = summary(render_intervals_ms)
    if render_intervals_ms and interval["mean_ms"]:
        interval["rendered_fps"] = 1000.0 / float(interval["mean_ms"])
    else:
        interval["rendered_fps"] = None

    return {
        "rows": len(rows),
        "rendered_rows": len(rendered),
        "target_fps": target_fps,
        "expected_interval_ms": period_ms,
        "cadence_band_ms": [lower, upper],
        "inter_frame": interval,
        "inter_frame_outside_expected_band": outside_band,
        "freshness_capture_to_surface": summary(freshness_ms),
        "decoder_queue_input_to_release": summary(queue_ms),
        "duplicates": duplicate,
        "skipped": skipped,
        "reordered": reordered,
        "first_frame_id": next((row.get("frame_id", 0) for row in rendered if row.get("frame_id", 0) > 0), None),
        "last_frame_id": last_frame_id or None,
    }


def write_markdown(path: Path, report: dict[str, object]) -> None:
    inter = report["inter_frame"]
    fresh = report["freshness_capture_to_surface"]
    queue = report["decoder_queue_input_to_release"]
    lines = [
        "# Tablet Bridge frame-pacing report",
        "",
        f"- Rows: {report['rows']} (rendered: {report['rendered_rows']})",
        f"- Target cadence: {report['target_fps']} FPS; expected interval {report['expected_interval_ms']:.3f} ms",
        f"- Out-of-band intervals: {report['inter_frame_outside_expected_band']}",
        f"- Frame IDs: duplicates={report['duplicates']}, skipped={report['skipped']}, reordered={report['reordered']}",
        "",
        "| Metric | p50 ms | p95 ms | p99 ms | max ms |",
        "|---|---:|---:|---:|---:|",
        f"| Inter-frame | {inter.get('p50_ms')} | {inter.get('p95_ms')} | {inter.get('p99_ms')} | {inter.get('max_ms')} |",
        f"| Capture → Surface | {fresh.get('p50_ms')} | {fresh.get('p95_ms')} | {fresh.get('p99_ms')} | {fresh.get('max_ms')} |",
        f"| Input queue → release | {queue.get('p50_ms')} | {queue.get('p95_ms')} | {queue.get('p99_ms')} | {queue.get('max_ms')} |",
        "",
        "The cadence band is ±25% of the requested refresh interval; this is a diagnostic band, not a product acceptance threshold.",
    ]
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--target-fps", type=float, default=60.0)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    report = analyze(load_rows(args.trace), args.target_fps)
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.write_text(payload)
    else:
        print(payload, end="")
    if args.markdown:
        write_markdown(args.markdown, report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
