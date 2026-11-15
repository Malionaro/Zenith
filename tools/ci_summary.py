#!/usr/bin/env python3
"""A job's result in one line, from a tool's log: for CI's live and busy jobs (tools/check.py --all
writes its own). The headline is the log's last result line ("397 passed, 4 failed", "within 1.5 x
the budget"), or says there was none (the tool stopped early); then each failing line (FAIL ...,
OVER BUDGET: ..., a Traceback's last line).

    python tools/ci_summary.py live_check live_check.log

On GitHub Actions it goes to the job's summary ($GITHUB_STEP_SUMMARY) and each failure becomes an
error annotation naming the check; elsewhere it is printed. Exits 0: the step that ran the tool fails
the job, this only reports it.
"""
import os
import pathlib
import re
import sys

RESULT = re.compile(r"^\d+ passed, \d+ failed|^within .* the budget|^OVER BUDGET")
FAILURE = re.compile(r"^(FAIL\b|OVER BUDGET:)")


def summarise(title: str, text: str) -> tuple[str, list[str]]:
    lines = text.splitlines()
    results = [l for l in lines if RESULT.match(l)]
    failures = [l for l in lines if FAILURE.match(l)]
    if "Traceback (most recent call last):" in text:
        # The exception's own line: the last line that isn't indented, after the traceback.
        tail = [l for l in lines[lines.index("Traceback (most recent call last):"):] if l and not l.startswith(" ")]
        failures.append("stopped: " + (tail[-1] if tail else "a Python exception"))
    if results:
        headline = f"{title}: {results[-1]}"
    elif lines:
        headline = f"{title}: no result line, the tool stopped early (last line: {lines[-1][:200]})"
    else:
        headline = f"{title}: no output"
    return headline, failures


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    title, path = sys.argv[1], pathlib.Path(sys.argv[2])
    text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    headline, failures = summarise(title, text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    out = [f"### {headline}", ""] + [f"- {l[:400]}" for l in failures] + [""]
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
    print("\n".join(out))
    if os.environ.get("GITHUB_ACTIONS"):
        for l in failures:
            # %, CR and LF are the annotation's own syntax.
            msg = l[:300].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title={title}::{msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
