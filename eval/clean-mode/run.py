#!/usr/bin/env python3
"""Clean-mode eval over the 19 frozen round-1 transcripts.

Two things this measures that the baseline round structurally could not.

**It separates the layers.** The round showed the user what *landed* —
LLM output after `TranscriptCleanupValidator` had merged it with the raw
transcript. A punctuation mark missing from that is missing for one of two
very different reasons: the model never produced it, or the validator
removed it. The round diagnosed "small-model behaviour" and pointed the
headline workstream at a model upgrade. This harness records both strings
per case, so the question is answered rather than assumed.

**It scores mechanically where it can.** Punctuation marks present or
absent, grammar-policy substitutions applied or not, numbers normalized or
not. Those need no expected output. The rest is a diff against the user's
expected, which lives in the round export.

    ./run.py --model llama-3.1-8b-instant           # baseline
    ./run.py --model llama-3.3-70b-versatile --delay 2
    ./run.py --model llama-3.1-8b-instant --no-llm  # validator only
"""

import argparse, json, pathlib, statistics, subprocess, sys, time

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "eval"))
from run_eval import read_key, post_json

GROQ = "https://api.groq.com/openai/v1/chat/completions"
OPENAI = "https://api.openai.com/v1/chat/completions"
CASES = json.loads((HERE / "transcripts.json").read_text())
VALIDATOR = HERE / "validator" / "validate"


def load_prompt():
    """The cleanup prompt from the built binary, never a copy.

    Same rule as the work-mode harness, for the same reason: a
    hand-pasted prompt scores the wording you had yesterday.
    """
    apps = sorted(pathlib.Path.home().glob(
        "Library/Developer/Xcode/DerivedData/Sayline-*/Build/Products/Debug/Sayline.app"),
        key=lambda p: p.stat().st_mtime, reverse=True)
    if not apps:
        sys.exit("No built Sayline.app — build first, the prompt comes from the binary.")
    out = subprocess.run([str(apps[0] / "Contents/MacOS/Sayline"), "--dump-config"],
                         capture_output=True, text=True)
    cfg = json.loads(out.stdout)
    for key in ("cleanPrompt", "cleanupPrompt", "transcriptCleanupPrompt"):
        if key in cfg:
            return cfg[key]
    sys.exit(f"binary exposes no cleanup prompt — has {sorted(cfg)}")


def validate_many(pairs):
    """Run the REAL validator, compiled, never a Python imitation."""
    stdin = "\n".join(json.dumps({"raw": r, "cleaned": c}) for r, c in pairs)
    proc = subprocess.run([str(VALIDATOR)], input=stdin + "\n",
                          capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        sys.exit(f"validator failed (rebuild it): {proc.stderr[:400]}")
    return [json.loads(l)["validated"] for l in proc.stdout.strip().splitlines()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="llama-3.1-8b-instant")
    ap.add_argument("--delay", type=float, default=0.0,
                    help="Groq TPM pacing — the work-mode bake-off learned this")
    ap.add_argument("--no-llm", action="store_true",
                    help="skip the model; validate the raw against itself")
    ap.add_argument("--out")
    a = ap.parse_args()

    system = load_prompt()
    # gpt-* model ids run on OpenAI — added 2026-08-18, the day Groq
    # removed every llama chat model and its remaining shelf failed the
    # bake-off (gpt-oss-20b on quality, qwen3.6 on latency).
    on_openai = a.model.startswith("gpt-")
    key = None if a.no_llm else read_key(
        "OPENAI_API_KEY" if on_openai else "GROQ_API_KEY",
        "OPENAI_API_KEY" if on_openai else "GROQ_API_KEY")

    rows, failures = [], []
    for case in CASES:
        raw = case["raw"]
        if a.no_llm:
            rows.append({**case, "llm": raw, "ms": 0.0})
            continue
        body, ms, err = post_json(OPENAI if on_openai else GROQ, key, {
            "model": a.model, "temperature": 0,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": raw}],
        })
        if err or not body:
            failures.append(f"{case['id']}: {err}")
            continue
        rows.append({**case, "llm": body["choices"][0]["message"]["content"].strip(),
                     "ms": ms})
        if a.delay:
            time.sleep(a.delay)

    # The harness refuses to report on partial data — the work-mode
    # bake-off's rule, kept.
    if failures:
        sys.exit(f"{len(failures)} call(s) failed, refusing to report a "
                 f"partial arm:\n  " + "\n  ".join(failures[:5]))

    validated = validate_many([(r["raw"], r["llm"]) for r in rows])
    for r, v in zip(rows, validated):
        r["validated"] = v

    # Model ids grew slashes (openai/gpt-oss-20b) and a slash in a
    # filename is a directory — the first bake-off after the llama
    # removal crashed HERE with its results already paid for.
    out = pathlib.Path(a.out or HERE / f"clean-{a.model.replace('/', '-')}.json")
    out.write_text(json.dumps(rows, indent=1, ensure_ascii=False))
    print(f"{len(rows)} cases -> {out}")
    if not a.no_llm:
        lat = [r["ms"] for r in rows]
        print(f"median {statistics.median(lat):.0f} ms   "
              f"p90 {sorted(lat)[int(len(lat)*0.9)]:.0f} ms   "
              f"(Clean's lock is ~200-500 ms)")


if __name__ == "__main__":
    main()
