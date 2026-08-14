#!/usr/bin/env python3
"""Runs the 18 taste scripts through a model, with or without few-shots.

Separate from `run.py` because they answer different questions. `run.py`
asks "does it break a fact" over 31 transcripts. This asks "does it sound
like the speaker" over the 18 scripts the user actually judged in round 1,
and its output is scored by `taste_score.py`.

Everything about the request — credentials, prompt source, message
shape — is imported from `run.py` rather than copied. That file's own
comment records what the last hand-copied prompt cost.

    ./taste_run.py --model gpt-4o-mini
    ./taste_run.py --model gpt-4o-mini --shots     # few-shot arm
"""

import argparse, json, pathlib, statistics, sys, time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run as harness   # SYSTEM, post_json, read_key, pinned_block, CANDIDATES

EMAIL_PROMPT = harness._load_prompt("workPromptEmail")
SCRIPTS = json.loads((HERE / "taste-scripts.json").read_text())
IDEALS = json.loads((HERE / "ideals-normalized.json").read_text())

# Which ideals become few-shots, and why these three.
#
# Chosen for coverage per token, not for being the best writing. The
# budget is the binding constraint: the prompt alone already sits at
# ~686 tokens and 1181 ms, against a 1.2 s line, so each example has to
# earn its place by teaching something the others do not.
#
#   N2  the shortest ideal in the set. One apology and not three, the
#       opener kept, two paragraphs. 96 tokens for four rules.
#   N1  pushback at someone senior: the position survives intact while
#       the delivery rounds off. This is the distinction the prompt
#       spends its longest rule explaining, and one example shows it.
#   E1  the only one carrying the full email shell, and it puts the bad
#       news in the first line.
#
# Deliberately no list example: `S1` already passes without one, and a
# numbered list is the most expensive shape per token in the set.
SHOT_IDS = ["N2", "N1", "E1"]

# N1's ideal opened with a dash that normalization turned into a sentence
# fragment ("...to this sprint. I'd push back"). A few-shot teaches its own
# infelicities, so this one clause is set by hand. Every word is unchanged.
OVERRIDES = {
    "N1": "Hey, on adding the export feature to this sprint, I'd push back "
          "on that. The sprint is genuinely full, so something would need to "
          "drop.\n\nIf we want to add export, I'd suggest dropping the "
          "settings redesign. I don't think we should just absorb the extra "
          "work, that usually doesn't end well.",
}


def shots():
    by_id = {c["id"]: c for c in SCRIPTS}
    out = []
    for cid in SHOT_IDS:
        ideal = OVERRIDES.get(cid) or IDEALS[cid][0]
        assert "—" not in ideal, f"{cid} still carries an em-dash"
        out.append({"role": "user", "content": by_id[cid]["raw"]})
        out.append({"role": "assistant", "content": ideal})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--shots", action="store_true")
    ap.add_argument("--delay", type=float, default=0.0)
    ap.add_argument("--out")
    a = ap.parse_args()

    url, provider = next((u, p) for m, u, p in harness.CANDIDATES if m == a.model)
    env = "GROQ_API_KEY" if provider == "groq" else "OPENAI_API_KEY"
    key = harness.read_key(env, env)
    examples = shots() if a.shots else []

    # The few-shot cases are held out of BOTH arms.
    #
    # Out of the few-shot arm because a model handed the answer will
    # reproduce it, which measures copying rather than taste. Out of the
    # bare arm too, even though nothing is leaked there, because two arms
    # scored over different case sets are not comparable — and the three
    # held out are not average cases, they were picked for being
    # instructive.
    skip = set(SHOT_IDS)
    rows = []
    for case in SCRIPTS:
        if case["id"] in skip or case.get("humanOnly"):
            continue
        # The email register, or its absence, is part of what is being
        # measured. The first version of this file sent `workPrompt` for
        # every case, so all six email scripts were scored against a
        # prompt production never uses for them — and then flagged for
        # missing the greeting and sign-off that the register is what
        # adds. Same second-copy-of-one-truth family as the hand-copied
        # prompt, arriving as a missing branch rather than a stale string.
        base = EMAIL_PROMPT if case["channel"] == "Email" else harness.SYSTEM
        pinned = harness.pinned_block(case["raw"])
        system = base if not pinned else f"{base}\n{pinned}"
        messages = ([{"role": "system", "content": system}] + examples
                    + [{"role": "user", "content": case["raw"]}])
        body, elapsed, error = harness.post_json(url, key, {
            "model": a.model, "temperature": 0, "messages": messages,
        })
        if error or not body:
            print(f"  {case['id']}: {error}", file=sys.stderr)
            continue
        rows.append({"id": case["id"], "raw": case["raw"], "ms": elapsed,
                     "rewrite": body["choices"][0]["message"]["content"].strip()})
        if a.delay:
            time.sleep(a.delay)

    tag = "shots" if a.shots else "bare"
    out = pathlib.Path(a.out or HERE / f"taste-{a.model}-{tag}.json")
    out.write_text(json.dumps(rows, indent=1, ensure_ascii=False))
    print(f"{len(rows)} rewrites -> {out}")
    print(f"median {statistics.median(r['ms'] for r in rows):.0f} ms")


if __name__ == "__main__":
    main()
