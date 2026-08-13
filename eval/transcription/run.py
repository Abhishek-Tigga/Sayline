#!/usr/bin/env python3
"""Transcription bake-off: which model hears this user correctly.

Same clip, every model, one score each. Ground truth is known because the
lines were read from a script, so word error rate is mechanical rather
than a judgement call.

    ./eval/transcription/recorder/record     # read the ten lines aloud
    ./eval/transcription/run.py

Why this matters beyond accuracy: work mode's fact guard can only protect
what the transcriber heard. Whisper has already turned Meera into
"Mira's", Karan into "Karen" and Designwell into "design well" on this
user's speech — no downstream guard can recover a name lost at this
layer.

Scored on two numbers, deliberately:
  WER            — overall word error rate, the usual measure
  key term hits  — did the names, brands and figures survive, which is
                   what actually costs the user something
"""

import argparse, json, statistics, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "eval"))
from run_eval import read_key

CLIPS = HERE / "clips"
SCRIPT = HERE / "script.json"
RESULTS = REPO / "eval" / "results.md"

CANDIDATES = [
    # (label, provider, model)
    ("whisper-large-v3 (current)", "groq",   "whisper-large-v3"),
    ("whisper-large-v3-turbo",     "groq",   "whisper-large-v3-turbo"),
    ("gpt-transcribe",             "openai", "gpt-transcribe"),
    ("gpt-live-transcribe",        "openai", "gpt-live-transcribe"),
    ("gpt-4o-transcribe",          "openai", "gpt-4o-transcribe"),
    ("gpt-4o-mini-transcribe",     "openai", "gpt-4o-mini-transcribe"),
]

ENDPOINTS = {
    "groq": "https://api.groq.com/openai/v1/audio/transcriptions",
    "openai": "https://api.openai.com/v1/audio/transcriptions",
}

# The words whose loss actually costs something. Overall WER treats "the"
# and "Designwell" as equal; the user does not.
KEY_TERMS = {
    "names-1": ["meera", "karan", "priya", "tuesday"],
    "names-2": ["arjun", "sneha", "rohan"],
    "brand": ["designwell"],
    "indian-num": ["lakh", "twenty", "thousand", "rupees"],
    "numbers": ["fifteen", "thirtieth", "fifty"],
    "time": ["four", "thirty", "two", "forty", "five", "friday"],
    "tech-1": ["oauth", "four", "zero", "three", "staging"],
    "tech-2": ["postgres", "redis"],
    "units": ["four", "hundred", "megs"],
    "mixed": ["ankit", "api"],
}


SPOKEN_NUMBERS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
    "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
    "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
    "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
    "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000",
    "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5",
    "thirteenth": "13", "thirtieth": "30", "twentieth": "20",
}


def normalize(text):
    """Words, with numbers reduced to digits.

    "fifteen" and "15" are the same answer — a model that writes digits is
    not less accurate, it is differently formatted, and for dictation the
    digits are arguably what the user wants typed. Scoring them as errors
    measured my preferences rather than the model's hearing. This mirrors
    what FactGuard already does for exactly the same reason.
    """
    words = "".join(c.lower() if (c.isalnum() or c.isspace()) else " " for c in text).split()
    out = []
    for word in words:
        stripped = word.rstrip("stndrh")  # 13th -> 13, 30th -> 30
        if word.isdigit():
            out.append(word)
        elif stripped.isdigit() and stripped:
            out.append(stripped)
        else:
            out.append(SPOKEN_NUMBERS.get(word, word))
    return out


def wer(reference, hypothesis):
    """Levenshtein over words, the standard measure."""
    ref, hyp = normalize(reference), normalize(hypothesis)
    if not ref:
        return 0.0
    grid = [[0] * (len(hyp) + 1) for _ in range(len(ref) + 1)]
    for i in range(len(ref) + 1):
        grid[i][0] = i
    for j in range(len(hyp) + 1):
        grid[0][j] = j
    for i in range(1, len(ref) + 1):
        for j in range(1, len(hyp) + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            grid[i][j] = min(grid[i - 1][j] + 1, grid[i][j - 1] + 1, grid[i - 1][j - 1] + cost)
    return grid[len(ref)][len(hyp)] / len(ref) * 100


def transcribe(provider, model, key, clip):
    """multipart/form-data by hand — no SDK, same as every other eval here."""
    import urllib.request, uuid
    boundary = f"----sayline{uuid.uuid4().hex}"
    audio = clip.read_bytes()
    parts = []
    # Pin the language. Without it, gpt-4o-transcribe heard an Indian
    # accent and returned the user's ENGLISH sentences written in
    # Devanagari and Urdu script — "आस्क अर्जुन टू लूप इन स्नेहा" is
    # "Ask Arjun to loop in Sneha" transliterated. That scored 209% WER
    # and would have condemned the model for a setting I never sent.
    for field, value in (("model", model), ("response_format", "text"), ("language", "en")):
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"\r\n\r\n{value}\r\n".encode())
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"{clip.name}\"\r\nContent-Type: audio/wav\r\n\r\n".encode())
    parts.append(audio)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)

    request = urllib.request.Request(
        ENDPOINTS[provider], data=body, method="POST",
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": f"multipart/form-data; boundary={boundary}",
                 "User-Agent": "Sayline-Eval/1.0"})
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=90) as response:
        text = response.read().decode(errors="replace").strip()
    return text, (time.monotonic() - started) * 1000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    args = ap.parse_args()

    script = {line["id"]: line["text"] for line in json.loads(SCRIPT.read_text())}
    clips = {p.stem: p for p in sorted(CLIPS.glob("*.wav"))}
    missing = [i for i in script if i not in clips]
    if not clips:
        sys.exit("No clips. Run ./eval/transcription/recorder/record first.")
    if missing:
        print(f"note: {len(missing)} line(s) not recorded: {', '.join(missing)}\n")

    keys = {"groq": read_key("GROQ_API_KEY", "GROQ_API_KEY"),
            "openai": read_key("OPENAI_API_KEY", "OPENAI_API_KEY")}
    rows = []

    for label, provider, model in CANDIDATES:
        if args.model and args.model != model:
            continue
        print(f"\n=== {label} ===")
        wers, latencies, hits, total_terms, errors = [], [], 0, 0, 0
        for clip_id, clip in clips.items():
            if clip_id not in script:
                continue
            try:
                heard, ms = transcribe(provider, model, keys[provider], clip)
            except Exception as exc:
                print(f"  {clip_id}: FAILED — {str(exc)[:90]}")
                errors += 1
                continue
            score = wer(script[clip_id], heard)
            wers.append(score)
            latencies.append(ms)
            words = set(normalize(heard))
            terms = [SPOKEN_NUMBERS.get(t, t) for t in KEY_TERMS.get(clip_id, [])]
            got = sum(1 for t in terms if t in words)
            hits += got
            total_terms += len(terms)
            flag = "" if got == len(terms) else f"  missed: {[t for t in terms if t not in words]}"
            print(f"  {clip_id:<11} WER {score:5.1f}%  {ms:5.0f}ms{flag}")
            if score > 0:
                print(f"              heard: {heard[:100]}")

        if errors and not wers:
            print(f"  ABORTED — every request failed")
            continue
        rows.append({
            "label": label, "wer": statistics.mean(wers) if wers else 0,
            "key": hits / total_terms * 100 if total_terms else 0,
            "ms": statistics.median(latencies) if latencies else 0,
            "n": len(wers), "errors": errors,
        })

    if not rows:
        sys.exit("\nnothing scored — nothing written")

    print("\n" + "=" * 64)
    print(f"{'model':<30}{'WER':>8}{'key terms':>12}{'median':>10}")
    for r in rows:
        print(f"{r['label']:<30}{r['wer']:>7.1f}%{r['key']:>11.0f}%{r['ms']:>9.0f}ms")

    with RESULTS.open("a") as fh:
        fh.write(f"\n### Transcription bake-off — {time.strftime('%Y-%m-%d %H:%M')}\n\n")
        fh.write(f"{len(clips)} clips read from a fixed script, so ground truth is known.\n")
        fh.write("Key terms are the names, brands and figures whose loss actually costs "
                 "something — overall WER treats \"the\" and \"Designwell\" as equal.\n\n")
        fh.write("| model | WER | key terms kept | median |\n|---|---|---|---|\n")
        for r in rows:
            fh.write(f"| `{r['label']}` | {r['wer']:.1f}% | {r['key']:.0f}% | {r['ms']:.0f} ms |\n")
    print(f"\nappended to {RESULTS.relative_to(REPO)}")


if __name__ == "__main__":
    main()
