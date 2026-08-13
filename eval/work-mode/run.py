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

import argparse, json, statistics, subprocess, sys, time, urllib.request
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

# The candidate work prompt. Deliberately NOT the production prompt — that
# is stage 3 and lands in WorkModeCleaner.swift. This exists so every
# model is asked for the same thing, which is the only way the comparison
# means anything.
SYSTEM = """You rewrite spoken dictation into clear written text.

The speaker was thinking out loud. Restructure freely: put the conclusion \
first, merge rambling sentences, cut thinking-out-loud and filler. Two \
clear sentences are better than five vague ones.

Rules you must not break:
- Never invent facts, names, numbers, dates, or commitments. If the \
speaker did not say it, it does not appear.
- Never reverse a statement. "I don't think we should" must not become \
"we should".
- Bullets ONLY if the speaker dictated an actual list. Never invent \
headers, greetings, or sign-offs.
- Output only the rewritten text. No preamble, no explanation, no quotes.
"""


def rewrite(model, url, key, raw, pinned, correction=None):
    messages = [{"role": "system", "content": SYSTEM}]
    user = raw if not pinned else f"{pinned}\n\n---\n\n{raw}"
    messages.append({"role": "user", "content": user})
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
    return proc.stdout.strip() if proc.returncode == 0 else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cases = json.loads(TRANSCRIPTS.read_text())
    print(f"{len(cases)} transcripts "
          f"({sum(1 for c in cases if c['id'].startswith('real'))} real)")

    if args.dry_run:
        print("\n--- system prompt ---")
        print(SYSTEM)
        print(f"--- example user turn ({cases[0]['id']}) ---")
        print(f"{pinned_block(cases[0]['raw'])}\n\n---\n\n{cases[0]['raw']}")
        return

    candidates = [c for c in CANDIDATES if not args.model or c[0] == args.model]
    keys = {"groq": read_key("GROQ_API_KEY", "GROQ_API_KEY"),
            "openai": read_key("OPENAI_API_KEY", "OPENAI_API_KEY")}
    rows = []

    for model, url, provider in candidates:
        print(f"\n=== {model} ===")
        first_pass, latencies, failures = [], [], []
        for case in cases:
            try:
                out, ms = rewrite(model, url, keys[provider], case["raw"], pinned_block(case["raw"]))
            except Exception as exc:
                if not failures:
                    print(f"  {case['id']}: request failed — {exc}")
                failures.append(f"{case['id']}: {exc}")
                continue
            first_pass.append((case, out))
            latencies.append(ms)

        if len(first_pass) < len(cases) * 0.8:
            # Refuse to report a number built on missing data. The first
            # version of this printed "0% broke a fact" for a model whose
            # every request had failed, which reads as a perfect score.
            print(f"  ABORTED — only {len(first_pass)}/{len(cases)} calls succeeded")
            if failures:
                print(f"  first error: {failures[0]}")
            continue

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

        n = len(first_pass) or 1
        row = {
            "model": model,
            "n": len(first_pass),
            "hallucination": len(broke) / n * 100,
            "rescued": rescued / len(broke) * 100 if broke else 0.0,
            "fallback": (len(broke) - rescued) / n * 100,
            "median_ms": statistics.median(latencies) if latencies else 0,
            "errors": len(failures),
        }
        rows.append(row)
        print(f"  broke a fact   {len(broke)}/{row['n']}  ({row['hallucination']:.0f}%)")
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
        fh.write("| model | broke a fact | retry rescued | ends in fallback | median |\n")
        fh.write("|---|---|---|---|---|\n")
        for r in rows:
            fh.write(f"| `{r['model']}` | {r['hallucination']:.0f}% | {r['rescued']:.0f}% "
                     f"| {r['fallback']:.0f}% | {r['median_ms']:.0f} ms |\n")
    print(f"\nappended to {RESULTS.relative_to(REPO)}")


if __name__ == "__main__":
    main()
