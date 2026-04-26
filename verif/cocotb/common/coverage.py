"""
Wrapper around cocotb_coverage.coverage to hide its API quirks and provide a
single import surface for the project tests.

Each coverage point is created lazily and registered globally. After every
test run we dump a JSON/HTML report to sim/coverage/.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from cocotb_coverage.coverage import (
    CoverPoint,
    CoverCross,
    coverage_db,
    coverage_section,
)

__all__ = ["CoverPoint", "CoverCross", "coverage_section", "dump_coverage"]


def _repo_root() -> Path:
    """Locate the repo root by walking up looking for a 'rtl/' directory.
    Falls back to the current working directory."""
    here = Path(__file__).resolve()
    for p in [here, *here.parents]:
        if (p / "rtl").is_dir() and (p / "verif").is_dir():
            return p
    return Path.cwd()


def dump_coverage(out_dir: Path | str | None = None, suite_name: str = "suite"):
    """Write the current coverage_db to JSON and a tiny human-readable
    text report. cocotb-coverage's report_coverage prints to stdout; we
    additionally serialise it for aggregation. If out_dir is omitted,
    drop the report under <repo_root>/sim/coverage/."""
    if out_dir is None:
        out_dir = _repo_root() / "sim" / "coverage"
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    summary = {}
    for name, cov in coverage_db.items():
        try:
            summary[name] = {
                "size":     cov.size,
                "coverage": cov.coverage,
                "cover_percentage": cov.cover_percentage,
            }
        except Exception:
            # cover crosses / different cov types may not have .size etc.
            try:
                summary[name] = {"cover_percentage": cov.cover_percentage}
            except Exception:
                summary[name] = {"info": "see cocotb-coverage stdout report"}

    json_path = out_dir / f"{suite_name}.json"
    json_path.write_text(json.dumps(summary, indent=2))

    txt_path = out_dir / f"{suite_name}.txt"
    with txt_path.open("w") as f:
        f.write(f"Functional coverage report — suite: {suite_name}\n")
        f.write("=" * 60 + "\n")
        for name, info in summary.items():
            pct = info.get("cover_percentage", 0)
            f.write(f"  {name:50s} {pct:6.2f}%\n")
