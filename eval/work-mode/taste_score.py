#!/usr/bin/env python3
"""Mechanical taste scorer — the half of the Phase C bar the guard cannot see.

`FactGuard` answers "did it break a fact". It says nothing about whether the
result sounds like the speaker, which is the thing taste round 1 actually
failed on. This scores the second half, and only the part that can be
checked without a human: the explicit bans, the length ceiling, the shape,
and the shell.

**It is deliberately not a quality score.** It cannot tell good writing from
bad. Every check here is a rule the user stated in round 1 or the prompt
states outright, so a pass means "broke none of the stated rules", not "the
user would send this". Round 2 is still the arbiter — this exists so a model
that violates a *stated* rule is rejected before it costs anyone a read.

Ground truth is `ideals.json`, the 15 rewrites the user accepted, supplied
2026-08-14. Opener anchors below are read off those ideals rather than
invented, so the check tracks what the user actually kept.

    ./taste_score.py --scored path/to/rewrites.json
    ./taste_score.py --model gpt-4o-mini          # runs the 18 first
"""

import argparse, json, pathlib, re, statistics, subprocess, sys

HERE = pathlib.Path(__file__).parent
VERIFIER = HERE / "verifier" / "verify"
SCRIPTS = json.loads((HERE / "taste-scripts.json").read_text())
IDEALS = json.loads((HERE / "ideals.json").read_text())

# The +12 email-shell allowance, same constant as `AppContext`. A greeting
# and a sign-off are structure the speaker did not dictate but does want.
EMAIL_ALLOWANCE = 12

# Openers the user kept in their own ideals. Presence of any anchor in the
# rewrite's opening is the check; the rewrite may word it differently.
OPENERS = {
    "T1": ["saw your comment", "your comment", "on the ticket"],
    "T2": ["status", "payments migration"],
    "T3": ["sorry", "blocked", "ping"],
    "T4": ["heads up", "vendor sandbox"],
    "E1": ["upfront", "integration timeline", "wanted to"],
    "E2": ["thanks for thinking", "thanks"],
    "E3": ["following up", "follow up", "invoice"],
    "E4": ["weekly update", "three things", "update"],
    "N1": ["export", "push back", "sprint"],
    "N2": ["my bad", "confusion", "misread"],
    "N3": ["correction", "last email", "quick correction"],
    "N4": ["sneha", "call out", "outage"],
    "S1": ["three things", "couple of things", "things"],
    "S2": ["retro", "move the retro"],
    "S3": ["proposal", "went through"],
    "I1": ["client call", "move the client call", "prepone"],
    "R1": ["status", "payments migration"],
    "R2": ["upfront", "integration timeline", "wanted to"],
}

# Upgrades the prompt bans by name, plus the corporate register round 1
# flagged. Left side is what a model reaches for; these are never what a
# person dictating actually said.
UPGRADES = [
    "utilize", "utilise", "as per", "remains incomplete", "endeavour",
    "endeavor", "whosoever", "aforementioned", "heretofore", "furthermore",
    "moreover", "additionally, i", "please be advised", "kindly note",
    "at your earliest convenience", "i trust this finds", "hope this email finds",
    "reach out to you regarding", "with regard to the", "in order to facilitate",
    "prior to", "subsequent to", "commence", "terminate", "ascertain",
    "exceptional", "unforeseen complexities", "presented challenges",
    "leverage", "circle back", "touch base", "going forward", "deliverables",
    "action item", "bandwidth constraints", "synergy", "streamline our",
]

# Softeners. These are the failure the guard structurally cannot catch: the
# facts all survive and the position quietly does not.
SOFTENERS = [
    "not fully aligned", "may face challenges", "might face challenges",
    "potentially at risk", "some concerns", "a few concerns",
    "i'm not entirely convinced", "not entirely sure that",
    "it may be worth considering", "perhaps we could consider",
    "i would humbly", "if it's not too much trouble", "at some point",
    "when convenient", "no rush at all", "whenever you get a chance, no pressure",
    "i defer to", "happy to go either way", "either way works",
]

PREAMBLE = re.compile(
    r"^\s*(here'?s|here is|sure[,!.]|certainly|rewritten|revised|cleaned"
    r"|i'?ve (rewritten|cleaned|tightened)|output:|result:)", re.I)

# Numbers the prompt wants spelled out — counts inside a sentence. Data
# (percentages, money, clock times, IDs) is explicitly left alone.
INLINE_DIGITS = re.compile(
    r"\b\d{1,2}\s+(hours?|minutes?|days?|weeks?|months?|things?|reasons?"
    r"|options?|people|candidates?|onsites?)\b", re.I)

APOLOGY = re.compile(r"\b(sorry|apolog(y|ies|ise|ize|izing)|my bad|my apologies)\b", re.I)


def words(t):
    return len(re.findall(r"\S+", t))


def verify_many(pairs):
    """One verifier process for the batch — the compiled guard, not a copy."""
    stdin = "\n".join(json.dumps({"raw": r, "rewrite": w}) for r, w in pairs)
    proc = subprocess.run([str(VERIFIER)], input=stdin + "\n",
                          capture_output=True, text=True, timeout=180)
    if proc.returncode != 0:
        sys.exit(f"verifier failed (rebuild it — a stale one scores with old "
                 f"rules): {proc.stderr[:400]}")
    return [json.loads(l)["violations"] for l in proc.stdout.strip().splitlines()]


def score_one(case, rewrite, violations):
    """Returns (fatal, soft) — lists of rule names broken.

    Fatal means the user would not send it without editing. Soft means it
    reads slightly off. The split matters: round 1's headline number was
    "send unedited", and only fatals move that.
    """
    fatal, soft = [], []
    raw, low = case["raw"], rewrite.lower()
    email = case["channel"] == "Email"

    if violations:
        kinds = sorted({v["kind"] if isinstance(v, dict) else v for v in violations})
        fatal.append("guard:" + ",".join(kinds))

    ceiling = words(raw) + (EMAIL_ALLOWANCE if email else 0)
    if words(rewrite) > ceiling:
        fatal.append(f"length:{words(rewrite)}>{ceiling}")

    if "—" in rewrite or "--" in rewrite:
        fatal.append("em-dash")

    hits = [u for u in UPGRADES if u in low]
    if hits:
        fatal.append("upgrade:" + hits[0])

    hits = [s for s in SOFTENERS if s in low]
    if hits:
        fatal.append("softened:" + hits[0])

    if PREAMBLE.search(rewrite):
        fatal.append("preamble")

    # A list that arrives without the line saying what it is a list of. The
    # prompt calls this out by name; it was a real round-1 failure.
    lines = rewrite.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^\s*(-|\*|\d+[.)])\s+", line):
            before = [l for l in lines[:i] if l.strip()]
            if not before:
                fatal.append("bullets-without-intro")
            break

    # Openers are content. Deleting one leaves a message starting mid-thought.
    anchors = OPENERS.get(case["id"], [])
    head = " ".join(rewrite.split()[:28]).lower()
    if anchors and not any(a in head for a in anchors):
        fatal.append("opener-dropped")

    if email:
        if not re.match(r"^\s*(hi|hey|hello|dear)\b", rewrite, re.I):
            soft.append("no-greeting")
        if not re.search(r"\b(best|thanks|regards|cheers)\b[,\s]*\n", rewrite, re.I):
            soft.append("no-signoff")

    if INLINE_DIGITS.search(rewrite):
        soft.append("digits-in-sentence")

    # One light apology, not three.
    said, wrote = len(APOLOGY.findall(raw)), len(APOLOGY.findall(rewrite))
    if wrote > max(said, 1):
        soft.append(f"apologies:{wrote}")

    # Never one dense block, when there was enough said to split.
    if words(raw) > 45 and "\n" not in rewrite.strip():
        soft.append("one-block")

    # A question they asked stays a question.
    if "?" in raw and "?" not in rewrite:
        fatal.append("question-lost")

    return fatal, soft


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scored", help="rewrites JSON to score")
    ap.add_argument("--label", default="")
    a = ap.parse_args()

    rows = json.loads(pathlib.Path(a.scored).read_text())
    by_id = {r["id"]: r for r in rows}
    cases = [c for c in SCRIPTS if c["id"] in by_id and not c.get("humanOnly")]
    if not cases:
        sys.exit("no taste-script ids in that file — is it the 31-transcript run?")

    violations = verify_many([(c["raw"], by_id[c["id"]]["rewrite"]) for c in cases])

    clean, results = 0, []
    for c, v in zip(cases, violations):
        fatal, soft = score_one(c, by_id[c["id"]]["rewrite"], v)
        results.append((c, fatal, soft))
        if not fatal:
            clean += 1

    label = a.label or pathlib.Path(a.scored).stem
    print(f"\n  taste score — {label}   ({len(cases)} cases)\n")
    for c, fatal, soft in results:
        mark = "PASS" if not fatal else "FAIL"
        notes = "; ".join(fatal + [f"({s})" for s in soft]) or "clean"
        print(f"  {mark}  {c['id']:<4} {c['channel']:<6} {notes}")

    softs = sum(len(s) for _, _, s in results)
    ms = [by_id[c["id"]].get("ms") for c in cases if by_id[c["id"]].get("ms")]

    # Reported separately because the ceiling is under dispute: four of the
    # fifteen rewrites the user accepted exceed it, each by one or two
    # words. Until that is settled, a model comparison dominated by the
    # ceiling would be comparing models on a rule the target itself fails.
    ceilingless = sum(
        1 for _, f, _ in results
        if not [x for x in f if not x.startswith(("length:", "guard:longer-than-speech"))]
    )
    print(f"\n  sendable unedited : {clean}/{len(cases)}  ({100*clean//len(cases)}%)")
    print(f"  ...ignoring ceiling: {ceilingless}/{len(cases)}  "
          f"({100*ceilingless//len(cases)}%)   [ceiling is disputed, see LEDGER]")
    print(f"  soft flags        : {softs}")
    if ms:
        print(f"  median latency    : {statistics.median(ms):.0f} ms")
    print()
    return 0 if clean == len(cases) else 1


if __name__ == "__main__":
    sys.exit(main())
