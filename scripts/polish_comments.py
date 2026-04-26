#!/usr/bin/env python3
"""One-shot script that trims the verbose ASCII-banner header comments from
RTL/test files. Keeps the first line (module name + one-line role), drops
the remaining banner block, and tightens whitespace.

Idempotent: running it again on already-trimmed files does nothing.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TARGETS = [
    REPO / "rtl",
    REPO / "verif",
    REPO / "scripts",
]

# Match a long banner block at the top of a file:
#   // =============================================
#   // <module>.sv -- <description spanning many lines>
#   //
#   // ... lots of explanatory prose ...
#   // =============================================
BANNER_SV = re.compile(
    r"^// =+\n(// .*\n)+// =+\n", re.MULTILINE
)
# Same pattern for Python ###### headers
BANNER_PY = re.compile(
    r'^"""\n.*?"""\n', re.MULTILINE | re.DOTALL
)


def trim_sv(text: str) -> str:
    m = BANNER_SV.match(text)
    if not m:
        return text
    block = m.group(0)
    lines = [l for l in block.splitlines() if l.startswith("// ") and l != "// "]
    # Keep the first non-separator content line as a 1-line // comment.
    keep = ""
    for l in lines:
        if l.startswith("// =") or not l.strip("/ "):
            continue
        keep = l + "\n"
        break
    return keep + text[m.end():]


def main() -> int:
    changed = 0
    for root in TARGETS:
        for sv in root.rglob("*.sv"):
            text = sv.read_text(encoding="utf-8")
            new  = trim_sv(text)
            if new != text:
                sv.write_text(new, encoding="utf-8", newline="\n")
                changed += 1
                print(f"  trimmed {sv.relative_to(REPO)}")
    print(f"\n{changed} file(s) trimmed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
