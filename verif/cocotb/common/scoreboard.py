"""
Reusable scoreboard helpers for cocotb tests.

A scoreboard pairs DUT observations with golden-model predictions. Each
mismatch is logged with full context; the overall status is queried at the
end of test.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Scoreboard:
    name: str = "scoreboard"
    pass_count: int = 0
    fail_count: int = 0
    failures: list[tuple[Any, Any, str]] = field(default_factory=list)

    def expect(self, observed, expected, label: str = ""):
        if observed == expected:
            self.pass_count += 1
        else:
            self.fail_count += 1
            self.failures.append((observed, expected, label))

    def assert_clean(self):
        if self.fail_count:
            head = self.failures[:3]
            detail = "\n".join(
                f"  [{l}] expected {e}, got {o}" for o, e, l in head
            )
            raise AssertionError(
                f"{self.name}: {self.fail_count} failures (first 3):\n{detail}"
            )

    def summary(self) -> str:
        return f"{self.name}: PASS={self.pass_count} FAIL={self.fail_count}"
