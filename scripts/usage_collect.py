#!/usr/bin/env python3
"""Collect per-request model usage from Claude Code transcript JSONL.

    usage_collect.py <transcript.jsonl> [--subagents DIR] [--detail] [--pretty]

Claude Code writes one JSONL line per content block, so every assistant line of
a request repeats the same `message.usage`. A request is counted once, by its
`requestId`. The provider's `input_tokens` excludes cached input, so the prompt
total is the sum of the three input fields; nothing is added twice. A request
whose line has no usage block is counted as unknown rather than as zero, and a
line that does not parse (the tail of a transcript still being written) marks
the record incomplete. Subagent transcripts under `<session>/subagents/` are
attributed to their agent id and the type from the sibling `.meta.json`.

The module also exports three small helpers other collectors share:
`fold_cumulative`, `fold_streams` and `span_union`/`span_sum`.
"""

import argparse
import glob
import json
import os
import sys

SCHEMA_VERSION = 1
USAGE_SCHEMA = "anthropic-exclusive"
USAGE_FIELDS = (
    "input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "output_tokens",
)


def empty_totals():
    totals = {field: 0 for field in USAGE_FIELDS}
    totals["thinking_tokens"] = 0
    totals["prompt_tokens_total"] = 0
    totals["requests"] = 0
    return totals


def add_usage(totals, usage):
    for field in USAGE_FIELDS:
        totals[field] += int(usage.get(field) or 0)
    details = usage.get("output_tokens_details") or {}
    totals["thinking_tokens"] += int(details.get("thinking_tokens") or 0)
    totals["prompt_tokens_total"] = (
        totals["input_tokens"]
        + totals["cache_creation_input_tokens"]
        + totals["cache_read_input_tokens"]
    )
    totals["requests"] += 1


def read_source(path, role, agent_id=None, agent_type=None):
    """Return (source_summary, requests) for one transcript file."""
    seen = set()
    requests = []
    lines = malformed = duplicates = without_usage = 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            lines += 1
            try:
                record = json.loads(raw)
            except ValueError:
                malformed += 1
                continue
            if record.get("type") != "assistant":
                continue
            message = record.get("message") or {}
            request_id = record.get("requestId") or message.get("id") or record.get("uuid")
            if request_id in seen:
                duplicates += 1
                continue
            seen.add(request_id)
            usage = message.get("usage")
            if not isinstance(usage, dict):
                without_usage += 1
                usage = None
            requests.append(
                {
                    "request_id": request_id,
                    "model": message.get("model"),
                    "timestamp": record.get("timestamp"),
                    "agent": agent_id or "main",
                    "usage": usage,
                }
            )
    summary = {
        "path": path,
        "role": role,
        "agent_id": agent_id or "main",
        "agent_type": agent_type,
        "lines": lines,
        "malformed_lines": malformed,
        "duplicate_lines_skipped": duplicates,
        "requests": len(requests),
        "requests_without_usage": without_usage,
        "complete": malformed == 0 and without_usage == 0,
    }
    return summary, requests


def subagent_sources(directory):
    for transcript in sorted(glob.glob(os.path.join(directory, "agent-*.jsonl"))):
        base = os.path.basename(transcript)[len("agent-") : -len(".jsonl")]
        agent_type = None
        meta_path = os.path.join(directory, f"agent-{base}.meta.json")
        if os.path.isfile(meta_path):
            try:
                with open(meta_path, encoding="utf-8") as handle:
                    agent_type = (json.load(handle) or {}).get("agentType")
            except (OSError, ValueError):
                agent_type = None
        yield transcript, base, agent_type


def collect(transcript, subagents=None, detail=False):
    sources = []
    all_requests = []
    summary, requests = read_source(transcript, "main")
    sources.append(summary)
    all_requests.extend(requests)
    if subagents and os.path.isdir(subagents):
        for path, agent_id, agent_type in subagent_sources(subagents):
            summary, requests = read_source(path, "subagent", agent_id, agent_type)
            sources.append(summary)
            all_requests.extend(requests)

    totals = empty_totals()
    by_agent = {}
    by_model = {}
    for source in sources:
        by_agent[source["agent_id"]] = empty_totals()
        by_agent[source["agent_id"]]["agent_type"] = source["agent_type"]
    for request in all_requests:
        if request["usage"] is None:
            continue
        add_usage(totals, request["usage"])
        add_usage(by_agent[request["agent"]], request["usage"])
        model = request["model"] or "unknown"
        by_model.setdefault(model, empty_totals())
        add_usage(by_model[model], request["usage"])

    result = {
        "schema_version": SCHEMA_VERSION,
        "collector": "usage_collect.py",
        "usage_schema": USAGE_SCHEMA,
        "sources": sources,
        "requests": len(all_requests),
        "duplicate_lines_skipped": sum(s["duplicate_lines_skipped"] for s in sources),
        "requests_without_usage": sum(s["requests_without_usage"] for s in sources),
        "malformed_lines": sum(s["malformed_lines"] for s in sources),
        "totals": totals,
        "by_agent": by_agent,
        "by_model": by_model,
        "complete": all(s["complete"] for s in sources),
        "provenance": {
            "measurement": "observed",
            "method": "transcript JSONL, first assistant line per requestId",
            "input_fields_are_exclusive": True,
        },
    }
    if detail:
        result["requests_detail"] = all_requests
    return result


def fold_cumulative(readings):
    """Fold a cumulative counter stream to its final value.

    Readings 100, 160, 160 mean 160 was used, not 420. A reading lower than the
    one before cannot be told apart from a new stream by the numbers alone, so it
    is flagged and the earlier high-water mark is kept; the caller decides.
    """
    value = 0
    flags = []
    for index, reading in enumerate(readings):
        reading = int(reading)
        if reading < value:
            flags.append(f"decrease_at_index_{index}")
            continue
        value = reading
    return value, flags


def fold_streams(streams):
    """Sum independent cumulative streams, each folded on its own."""
    total = 0
    flags = []
    for name, readings in streams.items():
        value, stream_flags = fold_cumulative(readings)
        total += value
        flags.extend(f"{name}:{flag}" for flag in stream_flags)
    return total, flags


def span_sum(spans):
    return sum(max(0, end - start) for start, end in spans)


def span_union(spans):
    """Wall time covered by overlapping (start, end) spans."""
    covered = 0
    current_start = current_end = None
    for start, end in sorted(spans):
        if current_end is None or start > current_end:
            if current_end is not None:
                covered += current_end - current_start
            current_start, current_end = start, end
        elif end > current_end:
            current_end = end
    if current_end is not None:
        covered += current_end - current_start
    return covered


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("transcript")
    parser.add_argument("--subagents", help="directory holding agent-*.jsonl transcripts")
    parser.add_argument("--detail", action="store_true", help="include per-request rows")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args(argv)
    if not os.path.isfile(args.transcript):
        print(f"usage_collect: no such transcript: {args.transcript}", file=sys.stderr)
        return 2
    result = collect(args.transcript, args.subagents, args.detail)
    json.dump(result, sys.stdout, indent=2 if args.pretty else None, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
