#!/usr/bin/env python3
"""Run json.mojo against the JSONTestSuite parsing corpus.

Clones https://github.com/nst/JSONTestSuite into .cache/ on first use,
packs the test files into one JSON document, and runs
tools/conformance.mojo over it. Exits non-zero on any y_/n_ failure.

Files that are not valid UTF-8 or contain raw NUL bytes are skipped:
parse_json takes a Mojo String, which is always valid UTF-8.
"""

import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".cache")
SUITE = os.path.join(CACHE, "JSONTestSuite")
CORPUS = os.path.join(CACHE, "conformance.json")


def main() -> int:
    if not os.path.isdir(SUITE):
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--depth", "1",
             "https://github.com/nst/JSONTestSuite.git", SUITE],
            check=True,
        )
    parsing = os.path.join(SUITE, "test_parsing")
    rows, skipped = [], 0
    for name in sorted(os.listdir(parsing)):
        raw = open(os.path.join(parsing, name), "rb").read()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            skipped += 1
            continue
        if "\x00" in text:
            skipped += 1
            continue
        rows.append([name, text])
    with open(CORPUS, "w") as f:
        json.dump(rows, f)
    print(f"{len(rows)} cases ({skipped} skipped: not representable as a Mojo String)")
    result = subprocess.run(
        ["mojo", "run", "-I", ROOT, os.path.join(ROOT, "tools", "conformance.mojo"), CORPUS]
    )
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
