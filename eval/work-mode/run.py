#!/usr/bin/env python3
"""Work mode's model bake-off.

Scores candidate rewriting models against the frozen transcript set using
`FactGuard` itself — via the compiled `verifier` binary, never a Python
copy of the rules. A scorer that drifts from production measures the
wrong thing, which this project has now paid for twice.

    ./run.py                      # every candidate
    ./run.py --model llama-3.3-70b-versatile
    ./run.py --dry-run            # prompts only, no API calls

Metrics, per the design's decision 7:
  hallucination rate  — transcripts where the first reply broke a fact
  retry rescue rate   — of those, how many the one corrective retry fixed
  fallback rate       — transcripts that ended up falling back to Clean
  latency             — median wall clock, first attempt, must fit +1s
"""

import argparse, json, pathlib, statistics, subprocess, sys, time, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "eval"))
from run_eval import read_key, post_json  # same credential path as every other eval

TRANSCRIPTS = HERE / "transcripts.json"
VERIFIER = HERE / "verifier" / "verify"
RESULTS = REPO / "eval" / "results.md"

GROQ = "https://api.groq.com/openai/v1/chat/completions"
OPENAI = "https://api.openai.com/v1/chat/completions"

CANDIDATES = [
    ("llama-3.1-8b-instant",    GROQ,   "groq"),    # today's Clean model — the baseline
    ("llama-3.3-70b-versatile", GROQ,   "groq"),
    ("gpt-4o-mini",             OPENAI, "openai"),
    ("gpt-4.1-mini",            OPENAI, "openai"),
]

# The system prompt, read from the BUILT BINARY rather than pasted here.
#
# It used to be a hand-copied string with a comment claiming it was lifted
# at build time. It was not, and the comment made that harder to notice.
# During the taste rebuild on 2026-08-14 that copy would have scored every
# arm of the bake-off against the OLD wording — the exact
# second-copy-of-one-truth failure this file's own comment warns about,
# for the third time in this repo.
#
# `--dump-config` now emits it, the same way the router eval stopped
# reimplementing the tool schema.
def _load_prompt(context="workPrompt"):
    apps = sorted(
        pathlib.Path.home().glob(
            "Library/Developer/Xcode/DerivedData/Sayline-*/Build/Products/Debug/Sayline.app"),
        key=lambda p: p.stat().st_mtime, reverse=True)
    if not apps:
        sys.exit("No built Sayline.app found — build first, the prompt comes from the binary.")
    out = subprocess.run([str(apps[0] / "Contents/MacOS/Sayline"), "--dump-config"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"--dump-config failed: {out.stderr[:300]}")
    config = json.loads(out.stdout)
    if context not in config:
        sys.exit(f"binary is older than this harness — no '{context}' in --dump-config")
    return config[context]


SYSTEM = _load_prompt()


# Few-shot examples, empty unless --shots. Module-level so `rewrite` keeps
# one message-building path: an arm that assembles its payload differently
# from the arm it is compared against is not a comparison.
EXAMPLES = []


def rewrite(model, url, key, raw, pinned, correction=None):
    """Constraints in the system message, transcript alone in the user one.

    The first version appended the pinned-facts block to the user content
    with a " | " delimiter, and a model echoed it verbatim into a rewrite:
    "...until we actually talk to sales. | negations: 2 — do not reverse
    any statement". Escaping the delimiter would treat the symptom; the
    disease is content-role confusion. Facts the model must respect are
    instructions, so they live where instructions live — which also makes
    a "do not echo this" instruction unnecessary.
    """
    system = SYSTEM if not pinned else f"{SYSTEM}\n{pinned}"
    messages = ([{"role": "system", "content": system}] + EXAMPLES
                + [{"role": "user", "content": raw}])
    if correction:
        messages.append({"role": "assistant", "content": correction["previous"]})
        messages.append({"role": "user", "content":
                         f"That reply broke a fact: {correction['why']}. "
                         f"Rewrite it again, keeping every fact from the original."})
    body, elapsed, error = post_json(url, key, {
        "model": model, "temperature": 0, "messages": messages,
    })
    if error or not body:
        raise RuntimeError(error or "empty response")
    return body["choices"][0]["message"]["content"].strip(), elapsed


def verify_many(pairs):
    """One verifier process for the whole batch."""
    stdin = "\n".join(json.dumps({"raw": r, "rewrite": w}) for r, w in pairs)
    proc = subprocess.run([str(VERIFIER)], input=stdin + "\n",
                          capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        sys.exit(f"verifier failed: {proc.stderr[:500]}")
    return [json.loads(line)["violations"] for line in proc.stdout.strip().splitlines()]


def pinned_block(raw):
    """The same extraction production will use, via the verifier's guard.

    Kept as a subprocess call rather than reimplemented so the prompt and
    the check cannot disagree — the property decision 2 is built on.
    """
    proc = subprocess.run([str(VERIFIER), "--pin"], input=json.dumps({"raw": raw}) + "\n",
                          capture_output=True, text=True)
    return proc.stdout.strip().replace(" | ", "\n") if proc.returncode == 0 else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--dry-run", action="store_true")
    # Groq's free tier is 12,000 tokens per minute. Phase B's prompt is
    # ~730 tokens per call, so an unpaced run trips the limit around call
    # 16 and the arm aborts — which is not a verdict on the model, it is a
    # verdict on the tier. Pacing lets the arm be measured at all; the
    # daily cap remains a real operational caveat for shipping, and belongs
    # in the recommendation rather than in an exclusion.
    ap.add_argument("--delay", type=float, default=0.0,
                    help="seconds to wait between calls, for rate-limited tiers")
    # Fable's consequence ruling, 2026-08-14: the first few-shot rejection
    # was unsound because every extra failure was `longer-than-speech`, the
    # class the ceiling ruling reclassified. Re-run on the full 31.
    ap.add_argument("--shots", action="store_true",
                    help="prepend the few-shot examples from the ideals")
    args = ap.parse_args()

    if args.shots:
        import taste_run
        globals()["EXAMPLES"] = taste_run.shots()
        print(f"few-shot arm: {len(EXAMPLES)//2} examples, "
              f"~{sum(len(m['content']) for m in EXAMPLES)//4} extra tokens")

    cases = json.loads(TRANSCRIPTS.read_text())
    print(f"{len(cases)} transcripts "
          f"({sum(1 for c in cases if c['id'].startswith('real'))} real)")

    if args.dry_run:
        # Printed from the same builder the real call uses. A preview with
        # its own formatting is a preview that can lie about the payload,
        # which is how the pin-block leak survived a dry run.
        example = cases[0]
        system = SYSTEM + "\n" + pinned_block(example["raw"])
        print(f"\n--- system message ({example['id']}) ---")
        print(system)
        print("\n--- user message ---")
        print(example["raw"])
        return

    candidates = [c for c in CANDIDATES if not args.model or c[0] == args.model]
    keys = {"groq": read_key("GROQ_API_KEY", "GROQ_API_KEY"),
            "openai": read_key("OPENAI_API_KEY", "OPENAI_API_KEY")}
    rows = []

    for model, url, provider in candidates:
        print(f"\n=== {model} ===")
        first_pass, latencies, failures = [], [], []
        # Saved so the novelty gate can be scored offline against real
        # output rather than invented examples — the same reason the
        # transcripts came from the user.
        saved = globals().setdefault("_saved", [])
        for case in cases:
            if args.delay: time.sleep(args.delay)
            try:
                out, ms = rewrite(model, url, keys[provider], case["raw"], pinned_block(case["raw"]))
            except Exception as exc:
                if not failures:
                    print(f"  {case['id']}: request failed — {exc}")
                failures.append(f"{case['id']}: {exc}")
                continue
            first_pass.append((case, out))
            latencies.append(ms)
            saved.append({"model": model, "id": case["id"], "cohort":
                          "real" if case["id"].startswith("real") else "made",
                          "raw": case["raw"], "rewrite": out, "ms": ms})

        if len(first_pass) < len(cases) * 0.8:
            # Refuse to report a number built on missing data. The first
            # version of this printed "0% broke a fact" for a model whose
            # every request had failed, which reads as a perfect score.
            print(f"  ABORTED — only {len(first_pass)}/{len(cases)} calls succeeded")
            if failures:
                print(f"  first error: {failures[0]}")
            continue

        # real-7 leaked the pin block into a rewrite. Now an assertion:
        # no fragment of the instructions may appear in any output.
        leaks = [c["id"] for c, o in first_pass
                 if any(marker in o.lower() for marker in
                        ("do not reverse", "must appear unchanged", "negations:",
                         "pinned", "timing:", "units:"))]
        if leaks:
            print(f"  PROMPT LEAKED into {len(leaks)} rewrite(s): {', '.join(leaks[:4])}")

        results = verify_many([(c["raw"], o) for c, o in first_pass])
        broke = [(c, o, v) for (c, o), v in zip(first_pass, results) if v]

        rescued = 0
        for case, previous, violations in broke:
            why = "; ".join(v["detail"] for v in violations)
            try:
                retry, _ = rewrite(model, url, keys[provider], case["raw"],
                                   pinned_block(case["raw"]),
                                   correction={"previous": previous, "why": why})
            except Exception:
                continue
            if not verify_many([(case["raw"], retry)])[0]:
                rescued += 1

        # Reported separately, not blended: every discriminating bug so
        # far came from the ten the user actually dictated.
        real_ids = {c["id"] for c, _ in first_pass if c["id"].startswith("real")}
        broke_ids = {c["id"] for c, _, _ in broke}
        real_broke = len(broke_ids & real_ids)
        made_broke = len(broke_ids) - real_broke
        made_n = len(first_pass) - len(real_ids)

        n = len(first_pass) or 1
        row = {
            "real": f"{real_broke}/{len(real_ids)}",
            "made": f"{made_broke}/{made_n}",
            "invented": sum(1 for _, _, vs in broke
                            if any(v["kind"].startswith("invented") for v in vs)),
            "model": model,
            "n": len(first_pass),
            "hallucination": len(broke) / n * 100,
            "rescued": rescued / len(broke) * 100 if broke else 0.0,
            "fallback": (len(broke) - rescued) / n * 100,
            "median_ms": statistics.median(latencies) if latencies else 0,
            "errors": len(failures),
        }
        rows.append(row)
        print(f"  broke a fact   {len(broke)}/{row['n']}  ({row['hallucination']:.0f}%)"
              f"   real {row['real']} · invented-set {row['made']}")
        print(f"  inventions     {row['invented']}  (the guard could not see these before)")
        print(f"  retry rescued  {rescued}/{len(broke)}  ({row['rescued']:.0f}%)")
        print(f"  ends in fallback              {row['fallback']:.0f}%")
        print(f"  median latency {row['median_ms']:.0f} ms")
        for case, out, violations in broke[:3]:
            print(f"    [{case['id']}] {', '.join(v['kind'] for v in violations)}")

    if not rows:
        sys.exit("\nno model produced a scorable run — nothing written to results.md")

    print("\n" + "=" * 62)
    print(f"{'model':<26}{'broke':>7}{'rescued':>9}{'fallback':>10}{'median':>9}")
    for r in rows:
        print(f"{r['model']:<26}{r['hallucination']:>6.0f}%{r['rescued']:>8.0f}%"
              f"{r['fallback']:>9.0f}%{r['median_ms']:>8.0f}ms")

    with RESULTS.open("a") as fh:
        fh.write(f"\n### Work mode model bake-off — {time.strftime('%Y-%m-%d %H:%M')}\n\n")
        fh.write(f"{len(cases)} transcripts, temperature 0, scored by FactGuard.\n\n")
        fh.write("| model | real 10 | invented 15 | inventions | retry rescued | fallback | median |\n")
        fh.write("|---|---|---|---|---|---|---|\n")
        for r in rows:
            fh.write(f"| `{r['model']}` | {r['real']} | {r['made']} | {r['invented']} "
                     f"| {r['rescued']:.0f}% | {r['fallback']:.0f}% | {r['median_ms']:.0f} ms |\n")
    outputs = HERE / "rewrites.json"
    outputs.write_text(json.dumps(globals().get("_saved", []), indent=2))
    print(f"\nappended to {RESULTS.relative_to(REPO)}; rewrites saved to {outputs.name}")


if __name__ == "__main__":
    main()
