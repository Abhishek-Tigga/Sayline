#!/usr/bin/env python3
"""Apple's on-device Foundation Model against the cloud models we ship.

Measurement only. Nothing here changes a production default; the decision
rules are pre-committed in `review/LEDGER.md` and this file only produces
the numbers they are applied to.

Both arms shell to the built binary (`--fm-clean` / `--fm-work`) rather
than reimplementing anything. The prompts, the guard, the retry and the
fallback semantics all live there, and this project has twice paid for a
harness that kept its own copy.

    ./run.py --arm clean      # 19 Clean cases, per-workstream scoring
    ./run.py --arm work       # 31 transcripts + the 13 taste scripts
    ./run.py --check          # availability only
"""

import argparse, json, pathlib, re, statistics, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "eval" / "clean-mode"))
sys.path.insert(0, str(REPO / "eval" / "work-mode"))

CLEAN_CASES = json.loads((REPO / "eval/clean-mode/transcripts.json").read_text())
CLEAN_BASE = json.loads((REPO / "eval/clean-mode/round1-baseline.json").read_text())
WORK_TRANSCRIPTS = json.loads((REPO / "eval/work-mode/transcripts.json").read_text())
TASTE_SCRIPTS = json.loads((REPO / "eval/work-mode/taste-scripts.json").read_text())

CLEAN_VALIDATOR = REPO / "eval/clean-mode/validator/validate"
POLISH = HERE / "polish" / "polish"

# The 8B's recorded numbers on this same set, from the Clean improvement
# round. The bar, not a guess.
EIGHT_B = {"punctuation": (6, 7), "grammar policy": (7, 7),
           "numbers + times": (5, 5), "self-correction": (7, 7)}
EIGHT_B_LATENCY = {"median": 283, "p90": 411}
# gpt-4.1-mini's recorded row from the work-mode bake-off.
FOUR_ONE_MINI = {"broke": 10, "rescued": 100, "fallback": 0, "median": 1071,
                 "taste_sendable": 13, "taste_total": 13}

# The per-workstream checks, identical to the ones the Clean round used —
# each is one thing the user's expected output demonstrably has.
WORKSTREAMS = {
    "punctuation": [("A1", r"Hey Priya,"), ("A2", r"fine, no errors"),
                    ("A2", r"\.\s+The only"), ("A3", r"night\?"),
                    ("A3", r"No rush, just"), ("A4", r"vendor:"),
                    ("A4", r"access, the API docs, and")],
    "grammar policy": [("B1", r"don'?t think caching"), ("B2", r"revert to me"),
                       ("B2", r"discussed the pricing"), ("B3", r"inform both teams"),
                       ("B3", r"prepone"), ("B4", r"I'll handle"), ("B4", r"[Yy]ou please")],
    "numbers + times": [("E1", r"47,500"), ("E1", r"4:30"), ("E1", r"2:45"),
                        ("B3", r"9:30"), ("C2", r"Finance")],
    "self-correction": [("C1", r"^Let's go there on Thursday\.$"), ("C2", r"45,000"),
                        ("C2", r"^(?!.*forty thousand).*$"), ("C3", r"Rohit"),
                        ("C3", r"Rohan"), ("C4", r"Tuesday.*Thursday"),
                        ("C5", r"design team")],
}


def binary():
    apps = sorted(pathlib.Path.home().glob(
        "Library/Developer/Xcode/DerivedData/Sayline-*/Build/Products/Debug/Sayline.app"),
        key=lambda p: p.stat().st_mtime, reverse=True)
    if not apps:
        sys.exit("No built Sayline.app — build first.")
    return str(apps[0] / "Contents/MacOS/Sayline")


def run_fm(mode, cases, timeout=1800):
    """One batch through the on-device model. Refusals arrive classified."""
    stdin = "\n".join(json.dumps({"id": c["id"], "raw": c["raw"]}) for c in cases)
    proc = subprocess.run([binary(), mode], input=stdin + "\n",
                          capture_output=True, text=True, timeout=timeout)
    rows, summary = [], {}
    for line in proc.stdout.strip().splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("summary"):
            summary = obj
        elif obj.get("fatal"):
            sys.exit(f"{obj['fatal']}: {obj.get('availability')}")
        else:
            rows.append(obj)
    if not rows:
        sys.exit(f"no output from {mode}. stderr: {proc.stderr[:400]}")
    return rows, summary


def latency(rows):
    ms = sorted(r["ms"] for r in rows if "ms" in r)
    if not ms:
        return None, None
    return statistics.median(ms), ms[int(len(ms) * 0.9)]


def clean_arm():
    cases = [c for c in CLEAN_CASES if not c["raw"].strip().startswith("(")]
    rows, summary = run_fm("--fm-clean", cases)
    by_id = {r["id"]: r for r in rows}

    refusals = {r["id"]: r["failure"] for r in rows if r.get("failure")}

    # The validator and the deterministic polish, exactly as production
    # applies them. A model comparison that skipped these would be
    # measuring a pipeline nobody runs.
    usable = [c for c in cases if by_id.get(c["id"], {}).get("out")]
    stdin = "\n".join(json.dumps({"raw": c["raw"], "cleaned": by_id[c["id"]]["out"]})
                      for c in usable)
    validated = [json.loads(l)["validated"] for l in subprocess.run(
        [str(CLEAN_VALIDATOR)], input=stdin + "\n", capture_output=True,
        text=True).stdout.strip().splitlines()]
    polished = subprocess.run([str(POLISH)], input="\n".join(validated) + "\n",
                              capture_output=True, text=True).stdout.rstrip("\n").split("\n")
    final = dict(zip([c["id"] for c in usable], polished))

    print(f"\n  CLEAN ARM — Apple on-device vs llama-3.1-8b-instant\n")
    print(f"  {'workstream':<18} {'8B':>8}   {'Apple FM':>9}")
    fm_total = base_total = count = 0
    for name, checks in WORKSTREAMS.items():
        got = sum(bool(re.search(p, final.get(i, ""))) for i, p in checks)
        base, total = EIGHT_B[name]
        fm_total += got; base_total += base; count += total
        print(f"  {name:<18} {base:>4}/{total:<3} {got:>6}/{total:<3}")
    print(f"  {'TOTAL':<18} {base_total:>4}/{count:<3} {fm_total:>6}/{count:<3}")

    med, p90 = latency(rows)
    print(f"\n  latency        8B {EIGHT_B_LATENCY['median']} ms median / "
          f"{EIGHT_B_LATENCY['p90']} ms p90")
    print(f"                 FM {med:.0f} ms median / {p90:.0f} ms p90")
    print(f"  warm-up        {summary.get('warmupMs', 0):.0f} ms (first call, prewarm)")
    print(f"  refusals       {len(refusals)}/{len(cases)}"
          + (f"  {refusals}" if refusals else ""))

    ships = (fm_total >= base_total and p90 <= 500 and not refusals)
    print(f"\n  DECISION: {'SHIP as default-when-available' if ships else 'CLOSE'}"
          f"  (needs score >= 8B, p90 <= 500 ms, zero refusals)")
    json.dump({"final": final, "rows": rows, "summary": summary},
              open(HERE / "clean-arm-results.json", "w"), indent=1)


def work_arm():
    rows, summary = run_fm("--fm-work", WORK_TRANSCRIPTS)
    broke = [r for r in rows if r.get("outcome") == "fellBack"]
    rescued = [r for r in rows if r.get("outcome") == "rescued"]
    first_broke = [r for r in rows if r.get("firstBroke")]
    refusals = [r for r in rows if str(r.get("failure", "")).startswith("fm-refusal")]
    errors = [r for r in rows if str(r.get("failure", "")).startswith("fm-error")]
    med, p90 = latency(rows)

    print(f"\n  WORK ARM — Apple on-device vs gpt-4.1-mini\n")
    print(f"  {'':<22} {'4.1-mini':>10}   {'Apple FM':>9}")
    n = len(rows)
    print(f"  {'broke a fact':<22} {FOUR_ONE_MINI['broke']:>9}% {100*len(first_broke)//max(n,1):>9}%")
    print(f"  {'retry rescued':<22} {FOUR_ONE_MINI['rescued']:>9}% "
          f"{(100*len(rescued)//max(len(first_broke),1)):>9}%")
    print(f"  {'ends in fallback':<22} {FOUR_ONE_MINI['fallback']:>9}% {100*len(broke)//max(n,1):>9}%")
    print(f"  {'median latency':<22} {FOUR_ONE_MINI['median']:>8}ms {med:>8.0f}ms")
    print(f"  {'p90 latency':<22} {'—':>10} {p90:>8.0f}ms")
    print(f"\n  refusals      {len(refusals)}/{n}   errors {len(errors)}/{n}")
    for r in refusals[:5]:
        print(f"    {r['id']}: {r['failure']}")
    for r in errors[:5]:
        print(f"    {r['id']}: {r['failure']}")
    print(f"  warm-up       {summary.get('warmupMs', 0):.0f} ms")

    # Taste, on the same 13 auto-runnable scripts the bake-off used.
    taste_cases = [c for c in TASTE_SCRIPTS
                   if not c.get("humanOnly") and c["id"] not in ("N2", "N1", "E1")]
    trows, _ = run_fm("--fm-work", taste_cases)
    out = [{"id": r["id"], "raw": next(c["raw"] for c in taste_cases if c["id"] == r["id"]),
            "rewrite": r.get("out", ""), "ms": r.get("ms", 0)} for r in trows]
    path = HERE / "work-arm-taste.json"
    path.write_text(json.dumps(out, indent=1, ensure_ascii=False))
    print(f"\n  taste scored by taste_score.py:")
    subprocess.run([sys.executable, str(REPO / "eval/work-mode/taste_score.py"),
                    "--scored", str(path), "--label", "Apple on-device FM"])
    json.dump({"rows": rows, "summary": summary},
              open(HERE / "work-arm-results.json", "w"), indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", choices=["clean", "work"])
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    availability = json.loads(subprocess.run([binary(), "--fm-check"],
                                             capture_output=True, text=True).stdout)
    if a.check or not availability.get("available"):
        print(f"  availability: {availability}")
        if not availability.get("available"):
            reason = availability.get("reason")
            hint = {
                "appleIntelligenceNotEnabled":
                    "System Settings > Apple Intelligence & Siri > turn it on. "
                    "First enable downloads the model; wait for it to finish.",
                "modelNotReady": "Model is still downloading. Try again later.",
                "deviceNotEligible": "This Mac cannot run it. Nothing to measure.",
            }.get(reason, "")
            if hint:
                print(f"  {hint}")
            sys.exit(0 if a.check else 2)
        return
    if a.arm == "clean":
        clean_arm()
    elif a.arm == "work":
        work_arm()
    else:
        ap.error("--arm is required unless --check")


if __name__ == "__main__":
    main()
