#!/usr/bin/env python3
"""Blind A/B: today's work-mode prompt, bare vs few-shot, judged by the user.

Phase B rejected few-shots twice on the mechanical scorer's verdict. The
user then judged live output rule-compliant but below their ideals — the
editorial quality the scorer structurally cannot measure — and the
round-2 handoff's own rule is "if the user disagrees with the scorer,
trust the user". So the question re-opens with the user as referee, and
this harness exists to put the two prompts in front of them blind.

The prompts come from `ab-blind/prompts-frozen.json`, a deliberate frozen
copy — the one exception to this repo's no-second-copy rule, with the
reason written down: the bare arm must be *today's* production prompt,
and a concurrent rebuild (the rule-gap fixes land in the same session)
would silently swap it out from under a pending experiment if the
harness read `--dump-config` live. The freeze is the experiment's
control, not a convenience copy.

    ./blind_ab.py --dry-run     # payloads only, no API calls
    ./blind_ab.py               # run both arms, emit the blind sheet

Reads  ab-blind/transcripts.json   [{id, channel, raw}, ...]
Writes ab-blind/blind-sheet.html   what the user judges (no latencies,
                                   no arm names — nothing to infer from)
       ab-blind/assignment-key.json  which side was which, per-pair
                                   latency, token counts, guard verdicts.
                                   NOT to be opened before the verdicts.
"""

import argparse, json, pathlib, random, statistics, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run as harness  # post_json, read_key, pinned_block, verify_many ONLY.
# harness.SYSTEM is deliberately not used: it reads the live binary, which
# the rule-gap rebuild changes. The frozen file is the experiment's truth.

AB = HERE / "ab-blind"
PROMPTS = json.loads((AB / "prompts-frozen.json").read_text())
SCRIPTS = {s["id"]: s for s in json.loads((HERE / "taste-scripts.json").read_text())}
IDEALS = json.loads((HERE / "ideals-normalized.json").read_text())

MODEL = "gpt-4.1-mini"
URL = "https://api.openai.com/v1/chat/completions"

# The three few-shots, per the experiment brief: E1 (email shell, bad news
# first), T4 (Slack heads-up), E4 (numbered update). The user's authored
# text, character-for-character from ideals-normalized.json — which is
# ideals.json with only the em-dashes replaced, the one permitted edit
# (examples teach every tic they contain, and the em-dash is banned).
# T4 has two accepted variants; the first is used. Input side is each
# case's round-1 spoken script.
SHOT_IDS = ["E1", "T4", "E4"]


def shots():
    out = []
    for cid in SHOT_IDS:
        ideal = IDEALS[cid][0]
        assert "—" not in ideal, f"{cid} still carries an em-dash"
        out.append({"role": "user", "content": SCRIPTS[cid]["raw"]})
        out.append({"role": "assistant", "content": ideal})
    return out


def build_messages(case, examples):
    base = PROMPTS["workPromptEmail"] if case["channel"] == "Email" else PROMPTS["workPrompt"]
    pinned = harness.pinned_block(case["raw"])
    system = base if not pinned else f"{base}\n{pinned}"
    return ([{"role": "system", "content": system}] + examples
            + [{"role": "user", "content": case["raw"]}])


HTML_HEAD = """<!doctype html><meta charset="utf-8">
<title>Work mode blind A/B</title>
<style>
 body{font:15px/1.5 -apple-system,sans-serif;max-width:880px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}
 .pair{border:1px solid #ddd;border-radius:8px;padding:1rem 1.2rem;margin:1.5rem 0}
 .raw{color:#666;font-style:italic;border-left:3px solid #ccc;padding-left:.8rem;margin:.5rem 0 1rem}
 .versions{display:grid;grid-template-columns:1fr 1fr;gap:1rem}
 .v{background:#f7f7f7;border-radius:6px;padding:.8rem;white-space:pre-wrap}
 .v h3{margin:0 0 .5rem;font-size:13px;color:#888;text-transform:uppercase}
 .verdict{margin-top:.8rem}
 .verdict label{margin-right:1.2rem;cursor:pointer}
 textarea{width:100%;margin-top:.5rem;font:13px/1.4 -apple-system,sans-serif}
 #export{position:sticky;bottom:1rem;padding:.6rem 1.4rem;font-size:15px;cursor:pointer}
 @media(max-width:700px){.versions{grid-template-columns:1fr}}
</style>
<h1>Work mode blind A/B</h1>
<p>For each pair: which version would you actually send? Judge at the
send-without-editing bar. A note on why is worth more than the pick alone.
<b>Export when done</b> — the button writes a file; marks in the page are
lost if the tab closes.</p>
"""

HTML_TAIL = """
<button id="export">Export verdicts</button>
<script>
const pairs = PAIR_IDS;
let dirty = false;
document.addEventListener('change', () => dirty = true);
window.addEventListener('beforeunload', e => { if (dirty) e.preventDefault(); });
document.getElementById('export').onclick = () => {
  const out = {};
  for (const id of pairs) {
    const pick = document.querySelector(`input[name="v-${id}"]:checked`);
    out[id] = { pick: pick ? pick.value : null,
                note: document.querySelector(`#note-${id}`).value };
  }
  const blob = new Blob([JSON.stringify(out, null, 1)], {type: 'application/json'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'ab-verdicts.json';
  a.click();
  dirty = false;
};
</script>
"""


def emit_sheet(rows):
    esc = lambda s: s.replace("&", "&amp;").replace("<", "&lt;")
    parts = [HTML_HEAD]
    for r in rows:
        parts.append(f"""<div class="pair"><h2>{r['id']} · {esc(r['channel'])}</h2>
<div class="raw">{esc(r['raw'])}</div>
<div class="versions">
 <div class="v"><h3>Version A</h3>{esc(r['A'])}</div>
 <div class="v"><h3>Version B</h3>{esc(r['B'])}</div>
</div>
<div class="verdict">
 <label><input type="radio" name="v-{r['id']}" value="A"> A</label>
 <label><input type="radio" name="v-{r['id']}" value="B"> B</label>
 <label><input type="radio" name="v-{r['id']}" value="tie"> Can't pick / both fine</label>
 <textarea id="note-{r['id']}" rows="2" placeholder="why (optional but valuable)"></textarea>
</div></div>""")
    parts.append(HTML_TAIL.replace("PAIR_IDS", json.dumps([r["id"] for r in rows])))
    (AB / "blind-sheet.html").write_text("".join(parts))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    cases = json.loads((AB / "transcripts.json").read_text())
    examples = shots()
    shot_chars = sum(len(m["content"]) for m in examples)
    print(f"{len(cases)} transcripts; few-shots ~{shot_chars // 4} extra tokens (chars/4)")

    if a.dry_run:
        c = cases[0]
        for name, ex in (("bare", []), ("few-shot", examples)):
            msgs = build_messages(c, ex)
            print(f"\n=== {name} arm, {c['id']} ===")
            for m in msgs:
                print(f"--- {m['role']} ---\n{m['content']}\n")
        return

    key = harness.read_key("OPENAI_API_KEY", "OPENAI_API_KEY")
    rows, keyrows = [], []
    for case in cases:
        arms = {}
        for name, ex in (("bare", []), ("shots", examples)):
            body, elapsed, error = harness.post_json(URL, key, {
                "model": MODEL, "temperature": 0,
                "messages": build_messages(case, ex)})
            if error or not body:
                sys.exit(f"{case['id']} {name}: {error}")
            arms[name] = {
                "text": body["choices"][0]["message"]["content"].strip(),
                "ms": elapsed,
                # exact, API-reported — not the chars/4 estimate
                "prompt_tokens": body.get("usage", {}).get("prompt_tokens"),
            }
        # The verdicts the guard would reach — recorded for the report,
        # never shown on the sheet.
        v_bare, v_shots = harness.verify_many(
            [(case["raw"], arms["bare"]["text"]), (case["raw"], arms["shots"]["text"])])
        arms["bare"]["violations"], arms["shots"]["violations"] = v_bare, v_shots

        # SystemRandom: the assignment must not be reproducible from the
        # script, or the blind isn't one.
        a_is = random.SystemRandom().choice(["bare", "shots"])
        b_is = "shots" if a_is == "bare" else "bare"
        rows.append({"id": case["id"], "channel": case["channel"], "raw": case["raw"],
                     "A": arms[a_is]["text"], "B": arms[b_is]["text"]})
        keyrows.append({"id": case["id"], "A": a_is, "B": b_is, "arms": arms})
        print(f"  {case['id']}: bare {arms['bare']['ms']:.0f}ms"
              f" ({arms['bare']['prompt_tokens']} tok)"
              f" · shots {arms['shots']['ms']:.0f}ms"
              f" ({arms['shots']['prompt_tokens']} tok)")

    emit_sheet(rows)
    med = {n: statistics.median(k["arms"][n]["ms"] for k in keyrows) for n in ("bare", "shots")}
    (AB / "assignment-key.json").write_text(json.dumps(
        {"model": MODEL, "median_ms": med, "pairs": keyrows}, indent=1, ensure_ascii=False))
    print(f"\nmedians: bare {med['bare']:.0f}ms · shots {med['shots']:.0f}ms")
    print(f"sheet -> {AB / 'blind-sheet.html'}")
    print("key   -> assignment-key.json (do not open before the verdicts)")


if __name__ == "__main__":
    main()
