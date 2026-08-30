#!/usr/bin/env python3
"""Recognize direct human lifecycle-control instructions from prompt text."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys


PHASE_ALIASES = {
    "setup": 0,
    "planning": 1,
    "plan": 1,
    "implementation": 2,
    "implement": 2,
    "review loop": 3,
    "code review": 3,
    "review": 3,
    "verification and commit": 4,
    "verify and commit": 4,
    "verification": 4,
    "verify": 4,
    "commit": 4,
    "pull request": 5,
    "pr": 5,
    "completion": 6,
    "complete": 6,
}

PHASE_PATTERN = (
    r"(?:phase\s*)?([0-7])\b|"
    + "|".join(re.escape(name) for name in sorted(PHASE_ALIASES, key=len, reverse=True))
)

NEGATION_PATTERN = re.compile(
    r"\b(?:do\s+not|don['’]?t|dont|never(?!\s+mind\b)|should\s+not|"
    r"shouldn['’]?t|cannot|can['’]?t)\b",
    re.IGNORECASE,
)

META_PATTERN = re.compile(
    r"\b(?:add|build|document|explain|support|recogn(?:i[sz]e|ition)|detect|handle|parse|"
    r"test|example|phrase|wording|instruct(?:ed|ion)?|being\s+told|be\s+told|"
    r"ability\s+to|(?:a|an|the|any|easy|clear|safe)\s+way\b|way\s+(?:for|to)\b)\b",
    re.IGNORECASE,
)

CLAUSE_BOUNDARY_PATTERN = re.compile(
    r"(?:[.!?;\n]+|,\s*(?:then|but|and\s+then)\b|\b(?:but|however|instead)\b)",
    re.IGNORECASE,
)


def current_clause_prefix(text: str, start: int, limit: int = 120) -> str:
    """Return only the clause that can modify the matched directive."""
    prefix = text[max(0, start - limit) : start]
    return CLAUSE_BOUNDARY_PATTERN.split(prefix)[-1]


def phase_from_text(value: str) -> int | None:
    value = re.sub(r"\s+", " ", value.strip().lower())
    match = re.fullmatch(r"(?:phase\s*)?([0-7])", value)
    if match:
        return int(match.group(1))
    return PHASE_ALIASES.get(value)


def result(action: str = "", target_phase: int | str = "", prompt: str = "") -> dict[str, object]:
    return {
        "action": action,
        "target_phase": target_phase,
        "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest() if action else "",
    }


def negated_before(text: str, start: int) -> bool:
    prefix = current_clause_prefix(text, start, 80)
    match = list(NEGATION_PATTERN.finditer(prefix))
    if not match:
        return False
    tail = prefix[match[-1].end() :]
    return len(re.findall(r"\b[\w’']+\b", tail)) <= 5


def meta_discussion(text: str, start: int) -> bool:
    prefix = current_clause_prefix(text, start)
    return bool(META_PATTERN.search(prefix))


def phase_after_keyword(text: str, keyword_end: int) -> int | None:
    suffix = text[keyword_end : keyword_end + 100]
    match = re.search(PHASE_PATTERN, suffix, re.IGNORECASE)
    if not match:
        return None
    return phase_from_text(match.group(0))


def explicit_directive(text: str, current_phase: int | None) -> dict[str, object] | None:
    match = re.search(
        r"(?im)^\s*/dx(skip|pause|resume|recover|jump)"
        r"(?:\s+(?:to\s+|at\s+)?([^\n;]+?))?\s*$",
        text,
    )
    if not match:
        match = re.search(
            r"(?im)^\s*/(?:dex|dx)\s+(stop|cancel|exit|disable|ignore|pause|leave|resume|"
            r"continue|complete|done|skip|recover|jump)(?:\s+(?:to\s+|at\s+)?([^\n;]+?))?\s*$",
            text,
        )
    if not match:
        return None

    command = match.group(1).lower()
    argument = (match.group(2) or "").strip().lower()
    if command in {"stop", "cancel", "exit", "disable", "ignore"}:
        return result("cancel", prompt=text)
    if command in {"pause", "leave"}:
        return result("pause", prompt=text)
    if command == "recover" and not argument:
        return result("recover", prompt=text)
    if command in {"resume", "continue"} and not argument:
        return result("resume", prompt=text)

    target = phase_from_text(argument) if argument else None
    if command in {"complete", "done", "skip"}:
        if target is not None:
            return result("jump", min(target + 1, 7), text)
        if current_phase is not None:
            return result("complete", min(current_phase + 1, 7), text)
        return None
    if command in {"jump", "resume", "continue"} and target is not None:
        return result("jump", target, text)
    return None


def direct_stop_or_pause(text: str) -> dict[str, object] | None:
    short_stop = re.fullmatch(
        r"\s*(?:please\s+)?(?:stop|quit|exit)(?:\s+(?:dex|now))?(?:\s+please)?[.!]?\s*",
        text,
        re.IGNORECASE,
    )
    if short_stop:
        return result("cancel", prompt=text)

    patterns = (
        (
            "cancel",
            re.compile(
                r"\b(stop|cancel|exit|disable|ignore)\s+(?:the\s+)?(?:dex\b|dex\s+)?"
                r"(?:phased\s+(?:approach|workflow)|phase\s+loop|review\s+loop|lifecycle|workflow|audit\s+loop)\b|"
                r"\b(stop|cancel|exit|disable|ignore)\s+dex\b",
                re.IGNORECASE,
            ),
        ),
        (
            "pause",
            re.compile(
                r"\b(pause|leave)\s+(?:the\s+)?(?:dex\s+)?"
                r"(?:review\s+loop|phase\s+loop|audit\s+loop|lifecycle|workflow)\b|"
                r"\b(pause|leave)\s+dex\b",
                re.IGNORECASE,
            ),
        ),
    )
    for action, pattern in patterns:
        for match in pattern.finditer(text):
            if negated_before(text, match.start()) or meta_discussion(text, match.start()):
                continue
            return result(action, prompt=text)
    return None


def direct_resume(text: str) -> dict[str, object] | None:
    pattern = re.compile(
        r"\b(resume|continue|restart)\s+(?:the\s+)?(?:dex\b|dex\s+)?"
        r"(?:lifecycle|workflow|phase\s+loop|audit\s+loop)?",
        re.IGNORECASE,
    )
    for match in pattern.finditer(text):
        matched = match.group(0).strip().lower()
        if "dex" not in matched and not re.search(r"lifecycle|workflow|phase\s+loop|audit\s+loop", matched):
            continue
        if negated_before(text, match.start()) or meta_discussion(text, match.start()):
            continue
        target = phase_after_keyword(text, match.end())
        if target is not None:
            return result("jump", target, text)
        return result("resume", prompt=text)
    return None


def direct_jump_or_skip(text: str, current_phase: int | None) -> dict[str, object] | None:
    stop_phase_work = re.compile(
        r"\bstop\s+(reviewing|(?:the\s+)?review|verifying|(?:the\s+)?verification)\b",
        re.IGNORECASE,
    )
    for match in stop_phase_work.finditer(text):
        if negated_before(text, match.start()) or meta_discussion(text, match.start()):
            continue
        named_phase = 3 if "review" in match.group(1).lower() else 4
        action = "complete" if current_phase == named_phase else "jump"
        return result(action, named_phase + 1, text)

    complete_current = re.compile(
        r"\b(?:skip|complete|finish|mark)\s+(?:the\s+)?(?:current|this)\s+phase"
        r"(?:\s+(?:as\s+)?(?:done|complete))?\b|"
        r"\bmark\s+(?:the\s+)?(?:current|this)\s+phase\s+(?:as\s+)?(?:done|complete)\b",
        re.IGNORECASE,
    )
    for match in complete_current.finditer(text):
        if negated_before(text, match.start()) or meta_discussion(text, match.start()):
            continue
        if current_phase is not None:
            return result("complete", min(current_phase + 1, 7), text)

    named_done = re.compile(
        rf"\b(?:skip|mark)\s+(?:the\s+)?({PHASE_PATTERN})(?:\s+phase)?"
        r"(?:\s+(?:as\s+)?(?:done|complete))?\b",
        re.IGNORECASE,
    )
    for match in named_done.finditer(text):
        if negated_before(text, match.start()) or meta_discussion(text, match.start()):
            continue
        phase = phase_from_text(match.group(1))
        if phase is None:
            continue
        target = min(phase + 1, 7)
        action = "complete" if current_phase == phase else "jump"
        return result(action, target, text)

    jump = re.compile(
        rf"\b(?:jump|skip\s+ahead)\s+(?:straight\s+)?(?:ahead\s+)?(?:to\s+)?"
        rf"(?:the\s+)?({PHASE_PATTERN})(?:\s+phase)?\b",
        re.IGNORECASE,
    )
    for match in jump.finditer(text):
        if negated_before(text, match.start()) or meta_discussion(text, match.start()):
            continue
        phase = phase_from_text(match.group(1))
        if phase is not None:
            return result("jump", phase, text)

    phase_names = "|".join(
        re.escape(name) for name in sorted(PHASE_ALIASES, key=len, reverse=True)
    )
    directed_move = re.compile(
        rf"\b(?:go|move)\s+(?:straight\s+)?to\s+"
        rf"(?:(phase\s*[0-7])\b|the\s+({phase_names})\s+phase\b)",
        re.IGNORECASE,
    )
    for match in directed_move.finditer(text):
        if negated_before(text, match.start()) or meta_discussion(text, match.start()):
            continue
        phase = phase_from_text(match.group(1) or match.group(2))
        if phase is not None:
            return result("jump", phase, text)

    lifecycle_move = re.compile(
        rf"\b(?:go|move)\s+(?:the\s+)?(?:dex(?:\s+lifecycle)?|lifecycle)\s+"
        rf"(?:straight\s+)?(?:to\s+)?(?:the\s+)?({PHASE_PATTERN})(?:\s+phase)?\b",
        re.IGNORECASE,
    )
    for match in lifecycle_move.finditer(text):
        if negated_before(text, match.start()) or meta_discussion(text, match.start()):
            continue
        phase = phase_from_text(match.group(1))
        if phase is not None:
            return result("jump", phase, text)
    return None


def parse_prompt(text: str, current_phase: int | None) -> dict[str, object]:
    text = text[:65536]
    explicit = explicit_directive(text, current_phase)
    if explicit:
        return explicit

    for parser in (
        direct_stop_or_pause,
        direct_resume,
        lambda value: direct_jump_or_skip(value, current_phase),
    ):
        parsed = parser(text)
        if parsed:
            return parsed
    return result()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", default="")
    parser.add_argument("--format", choices=("json", "tsv"), default="json")
    args = parser.parse_args()
    current_phase = int(args.phase) if re.fullmatch(r"[0-6]", args.phase) else None
    prompt = sys.stdin.read()
    parsed = parse_prompt(prompt, current_phase)
    if parsed["action"]:
        # parse_prompt bounds its regex scan to the prompt's head, but the
        # attribution hash has to cover everything the human actually sent.
        parsed["prompt_sha256"] = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
    if args.format == "tsv":
        target = parsed["target_phase"] if parsed["target_phase"] != "" else "-"
        print(
            "\t".join(
                str(value)
                for value in (parsed["action"], target, parsed["prompt_sha256"])
            )
        )
    else:
        print(json.dumps(parsed, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
