#!/usr/bin/env python3
"""
Pre-process the SystemVerilog sources for Yosys synthesis.

Yosys's built-in SV parser does not accept package imports in the module
header (e.g. `module foo import pkg::*; #(...) (...)`). This script rewrites
that pattern to put the import on a separate line above the module:

    import pkg::*;
    module foo #(
      ...
    );

The rewritten files land under synth/preproc/<same_relative_path>.

Usage:
    python scripts/synth_preproc.py
"""
from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RTL = REPO / "rtl"
OUT = REPO / "synth" / "preproc"


# Match:
#   module <name>
#     import pkg::*;
# possibly followed by # or ( on next non-blank line
MODULE_IMPORT_RE = re.compile(
    r"(module\s+(\w+)\b)\s*(import\s+\w+::\*\s*;)\s*",
    re.MULTILINE,
)


def transform(text: str) -> str:
    def repl(m):
        modkw, name, imp = m.group(1), m.group(2), m.group(3)
        # Place import above 'module <name>' so the names are in scope.
        return f"{imp}\n{modkw}"
    return MODULE_IMPORT_RE.sub(repl, text)


def main() -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    for sv in sorted(RTL.rglob("*.sv")):
        rel = sv.relative_to(RTL)
        dest = OUT / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        text = sv.read_text(encoding="utf-8")
        new_text = transform(text)
        dest.write_text(new_text, encoding="utf-8")
        if new_text != text:
            print(f"  rewrote {rel}")
        else:
            print(f"  copied  {rel}")

    print(f"\nWrote pre-processed sources to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
