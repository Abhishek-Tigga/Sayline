#!/usr/bin/env python3
"""The language-match rule behind the Apple Intelligence diagnosis.

Apple's `UnavailableReason` reports a language mismatch as
`appleIntelligenceNotEnabled` — which sends the user to a settings pane
where the switch they are told to flip does not exist. Observed live on
2026-08-14: Mac on en-IN, Siri on en-US, no toggle, no download. Matching
Siri to the Mac changed the reason to `modelNotReady` and the download
started.

The comparator is the part of that diagnosis with logic in it, so it is
tested here — through the binary, because the binary is what ships.
"""
import json, pathlib, subprocess, sys

APP = sorted(pathlib.Path.home().glob(
    "Library/Developer/Xcode/DerivedData/Sayline-*/Build/Products/Debug/Sayline.app"),
    key=lambda p: p.stat().st_mtime, reverse=True)
if not APP:
    sys.exit("No built Sayline.app — build first.")
BIN = str(APP[0] / "Contents/MacOS/Sayline")

CASES = [
    # The live failure, and its fix.
    ("en-IN", "en-US", False, "the observed mismatch"),
    ("en-IN", "en-IN", True,  "the fix that started the download"),
    # Region matters — this is the whole point of the rule.
    ("en-US", "en-GB", False, "same language, different region"),
    ("en-IN", "hi-IN", False, "different language, same region"),
    # Separator and case are not differences.
    ("en_IN", "en-IN", True,  "underscore and hyphen are the same tag"),
    ("EN-in", "en-IN", True,  "case is not a difference"),
    # A bare language tag cannot contradict a regioned one.
    ("en",    "en-IN", True,  "no region stated means no region conflict"),
    ("en-IN", "en",    True,  "and the same in reverse"),
]

bad = 0
for mac, siri, want, why in CASES:
    out = json.loads(subprocess.run([BIN, "--fm-check", mac, siri],
                                    capture_output=True, text=True).stdout)
    ok = out.get("same") == want
    bad += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} {why:<42} {mac} vs {siri} -> {out.get('same')}")

print(f"\n{'all passed' if not bad else f'{bad} FAILED'}")
sys.exit(0 if not bad else 1)
