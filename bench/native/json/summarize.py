#!/usr/bin/env python3
"""Combine an interrupted baseline's clean rounds with replacement rounds.

Keep both original runs. Exclude a whole paired round, never selected slow
samples; every accepted round must contain exactly the same commands.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics as st

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("primary", type=Path)
p.add_argument("replacement", type=Path)
p.add_argument("--exclude-primary-round", type=int, action="append", default=[])
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
metadata = [json.loads((d / "metadata.json").read_text()) for d in (a.primary, a.replacement)]
for key in ("node", "platform", "cpu", "cpu_quota", "versions", "sources_sha256", "ren_sha256", "config", "commands"):
    if metadata[0][key] != metadata[1][key]:
        raise RuntimeError(f"runs do not match: {key}")
commands = {row[0] for row in metadata[0]["commands"]}
values, lineage, outputs, failures = defaultdict(list), [], {}, {}
for directory in (a.primary, a.replacement):
    rounds = defaultdict(list)
    for line in (directory / "samples.jsonl").read_text().splitlines():
        row = json.loads(line)
        if row["round"] < 0 or (directory == a.primary and row["round"] in a.exclude_primary_round):
            continue
        rounds[row["round"]].append(row)
    for round_, rows in sorted(rounds.items()):
        if len(rows) != len(commands) or {row["name"] for row in rows} != commands:
            raise RuntimeError(f"incomplete paired round: {directory} {round_}")
        lineage.append({"source": str(directory), "round": round_})
        for row in rows:
            name = row["name"]
            if row["returncode"]:
                if not (name.startswith("examples/") and name.endswith("/build")):
                    raise RuntimeError(f"unexpected failure: {name}")
                failures[name] = {"returncode": row["returncode"], "diagnostic": row["stderr"].strip()}
            elif row["output"] != outputs.setdefault(name, row["output"]):
                raise RuntimeError(f"output changed between runs: {name}")
            values[name].append(row["seconds"])
summary = {name: {"median_seconds": st.median(xs), "min_seconds": min(xs), "max_seconds": max(xs)} for name, xs in sorted(values.items())}
cfg = metadata[0]["config"]
pairs = []
for mode in ("decode", "encode", "roundtrip"):
    for language in ("ren", "rust", "go"):
        prefix = f"json/{mode}/{language}"
        pairs.append((prefix, f"{prefix}/{cfg['rounds']}", f"{prefix}/1", cfg["size"] * (cfg["rounds"] - 1)))
for variant in ("log-today-snp", "log-passed-site", "log-walk", "html-today", "html-plan", "log-rust", "html-rust"):
    prefix = f"templates/{variant}"
    pairs.append((prefix, f"{prefix}/{cfg['template_ops']}", f"{prefix}/0", cfg["template_ops"]))
paired = {}
for name, full, base, count in pairs:
    xs = [(f - b) * 1e9 / count for f, b in zip(values[full], values[base])]
    paired[name] = {"median_ns_per_operation": st.median(xs), "min_ns_per_operation": min(xs), "max_ns_per_operation": max(xs)}
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps({"selection": {"accepted_rounds": lineage, "excluded_primary_rounds": a.exclude_primary_round}, "timings": summary, "paired": paired, "outputs": outputs, "unavailable_builds": failures}, indent=2) + "\n")
print(f"{len(lineage)} complete paired rounds summarized in {a.output}")
