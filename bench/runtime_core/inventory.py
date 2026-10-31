#!/usr/bin/env python3
"""List family reference expect tests; this is an inventory, not execution."""

from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
for name in ["test_services.ml", "test_services_review.ml", "test_actors.ml",
             "test_structured_actors.ml", "test_structured_actors_10b.ml"]:
    source = root / "test" / name
    text = source.read_text()
    for match in re.finditer(r'let%expect_test\s+"((?:[^"\\]|\\.)*)"', text):
        title = match.group(1)
        if name == "test_services.ml" and not re.match(r'\[s[678] ', title):
            continue
        line = text[:match.start()].count("\n") + 1
        print(f"test/{name}:{line}\t{title}")
