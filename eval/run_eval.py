#!/usr/bin/env python3
"""Agent router eval harness.

Runs eval/router-test-set.json against one arm of the router and scores it
mechanically. See eval/README.md for the rules and BACKLOG.md for the plan.

  ./run_eval.py --arm groq-tools          # A: current production behavior
  ./run_eval.py --arm groq-json           # B: Groq JSON object mode
  ./run_eval.py --arm openai --model gpt-5-nano   # C: OpenAI strict tools
  ./run_eval.py --arm groq-tools --dry-run        # payload check, no API calls

The system prompt and tool definitions are read out of the real
AgentRouter.swift at run time (see swift_helper below) rather than copied
here. A copy would drift, and a drifted harness measures the wrong thing
while looking perfectly healthy.

Pane strings are resolved through the real SettingsPaneCatalog for the same
reason, so scoring reflects which pane would actually open rather than what
the model happened to type.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parent
REPO = EVAL_DIR.parent
SRC = REPO / "Sources" / "Sayline"
TEST_SET = EVAL_DIR / "router-test-set.json"
RESULTS = EVAL_DIR / "results.md"

GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
OPENAI_URL = "https://api.openai.com/v1/chat/completions"
GROQ_MODEL = "llama-3.3-70b-versatile"

# Tool name -> (action name used in the test set, {tool arg: test-set arg}).
# The test set speaks AgentAction's vocabulary; the wire speaks the tool
# schema's. This is the only place the two are bridged.
TOOL_TO_ACTION = {
    "open_app": ("openApp", {"app_name": "name"}),
    "close_app": ("closeApp", {"app_name": "name"}),
    "find_file": ("findFile", {"query": "query", "folder": "folder", "subpath": "subpath"}),
    "open_folder": ("openFolder", {"folder": "folder", "subpath": "subpath"}),
    "open_system_setting": ("openSystemSetting", {"pane": "pane"}),
    "lock_screen": ("lockScreen", {}),
    "set_volume": ("setVolume", {"change": "change"}),
    "set_wifi": ("setWiFi", {"enabled": "enabled"}),
    "set_dark_mode": ("setDarkMode", {"enabled": "enabled"}),
    "empty_trash": ("emptyTrash", {}),
    "take_screenshot": ("takeScreenshot", {}),
    "answer_system_query": ("answerQuery", {"query": "query"}),
}


# --------------------------------------------------------------------------
# Reading the real Swift definitions
# --------------------------------------------------------------------------

SWIFT_STUBS = """
enum TranscriptionError: Error { case missingAPIKey, invalidResponse, apiError(String) }
enum APIKeyProvider { static var groqAPIKey: String? { nil } }
"""

SWIFT_MAIN = """
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
if mode == "dump-config" {
    let router = AgentRouter()
    let payload: [String: Any] = ["systemPrompt": router.systemPrompt, "tools": router.tools]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else if mode == "pane-phrases" {
    // For each transcript, what phrase sits before "settings" and where
    // does the catalog send it? Lets the harness reproduce
    // AgentRouter.correctedSettingsPane without reimplementing either the
    // phrase extraction or the matching in Python.
    let byID = Dictionary(SettingsPaneCatalog.panes.map { ($0.bundleID, $0.displayName) },
                          uniquingKeysWith: { a, _ in a })
    var out: [String: [String: String]] = [:]
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        guard let phrase = AgentRouter.panePhrase(in: line) else { continue }
        if let id = SettingsPaneCatalog.bundleID(forPaneName: phrase) {
            out[line] = ["phrase": phrase, "displayName": byID[id] ?? id]
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else if mode == "resolve-panes" {
    let byID = Dictionary(SettingsPaneCatalog.panes.map { ($0.bundleID, $0.displayName) },
                          uniquingKeysWith: { a, _ in a })
    var out: [String: [String: String]] = [:]
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        if let id = SettingsPaneCatalog.bundleID(forPaneName: line) {
            out[line] = ["kind": "pane", "displayName": byID[id] ?? id, "bundleID": id]
        } else if SettingsPaneCatalog.meansSystemSettingsApp(line) {
            out[line] = ["kind": "app"]
        } else {
            out[line] = ["kind": "fallback"]
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
"""


def swift_helper(mode, stdin_text=""):
    """Concatenate the real sources with stubs + a main, run under `swift`."""
    parts = [
        (SRC / "AgentAction.swift").read_text(),
        (SRC / "SettingsPaneCatalog.swift").read_text(),
        (SRC / "AgentRouter.swift").read_text(),
        SWIFT_STUBS,
        SWIFT_MAIN,
    ]
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "helper.swift"
        script.write_text("\n".join(parts))
        proc = subprocess.run(
            ["swift", str(script), mode],
            input=stdin_text, capture_output=True, text=True, timeout=300,
        )
    if proc.returncode != 0:
        sys.exit(f"swift helper failed ({mode}):\n{proc.stderr[:3000]}")
    return json.loads(proc.stdout)


# --------------------------------------------------------------------------
# Credentials — never stored in this file or anywhere in the repo
# --------------------------------------------------------------------------

def read_key(env_var, keychain_account):
    if os.environ.get(env_var):
        return os.environ[env_var]
    proc = subprocess.run(
        ["security", "find-generic-password", "-s", "com.abhishektigga.sayline",
         "-a", keychain_account, "-w"],
        capture_output=True, text=True,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        return proc.stdout.strip()
    sys.exit(
        f"No credential found. Set ${env_var}, or add it to Keychain:\n"
        f'  security add-generic-password -U -s "com.abhishektigga.sayline" '
        f'-a "{keychain_account}" -w'
    )


def post_json(url, key, payload, timeout=60):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            # Required, not cosmetic: Groq sits behind Cloudflare, which
            # rejects Python's default "Python-urllib/x.y" agent outright
            # with HTTP 403 "error code: 1010" — no rate-limit headers, no
            # JSON body, nothing that looks like an API error. That is what
            # sank the first A/B attempt on 2026-08-08 and got misread as a
            # possible bad key. Any honest agent string is accepted; this
            # does not need to impersonate a browser.
            "User-Agent": "Sayline-Eval/1.0",
        },
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read())
        return body, (time.monotonic() - started) * 1000, None
    except urllib.error.HTTPError as e:
        return None, (time.monotonic() - started) * 1000, e.read().decode(errors="replace")
    except Exception as e:  # network/timeout
        return None, (time.monotonic() - started) * 1000, f"{type(e).__name__}: {e}"


# --------------------------------------------------------------------------
# Arms
# --------------------------------------------------------------------------

def prose_from_tools(tools):
    """Render the tool schema as prose for the JSON-mode arm.

    Generated from the same array the tool-calling arm sends, so arms B and A
    are describing an identical action set — the only variable under test is
    how the model is asked to reply.
    """
    lines = []
    for t in tools:
        fn = t["function"]
        params = fn.get("parameters", {}).get("properties", {}) or {}
        required = set(fn.get("parameters", {}).get("required", []))
        sig = []
        for name, spec in params.items():
            bits = spec.get("type", "string")
            if "enum" in spec:
                bits = " | ".join(json.dumps(v) for v in spec["enum"])
            sig.append(f"{name}{'' if name in required else '?'}: {bits}")
        lines.append(f'- {fn["name"]}({", ".join(sig)}) — {fn.get("description","")}')
    return "\n".join(lines)


JSON_MODE_SUFFIX = """

Reply with a JSON object only, in exactly this shape:
{"actions": [{"name": "<action name>", "arguments": {<arguments>}}]}

Use one entry per action, in the order the user said them. If the request
matches no action at all, reply with {"actions": []} — never invent an
action to avoid an empty list.

Available actions:
"""


def openai_strict_tools(tools):
    """OpenAI strict mode requires every property listed in `required` and
    `additionalProperties: false`, so genuinely optional parameters become
    nullable instead of absent."""
    out = []
    for t in tools:
        fn = t["function"]
        params = fn.get("parameters", {}) or {}
        props = {k: dict(v) for k, v in (params.get("properties") or {}).items()}
        originally_required = set(params.get("required", []))
        for name, spec in props.items():
            if name not in originally_required:
                base = spec.get("type", "string")
                spec["type"] = [base, "null"]
        out.append({
            "type": "function",
            "function": {
                "name": fn["name"],
                "description": fn.get("description", ""),
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": props,
                    "required": list(props.keys()),
                    "additionalProperties": False,
                },
            },
        })
    return out


def parse_tool_calls(message):
    calls = message.get("tool_calls") or []
    parsed = []
    for c in calls:
        fn = c.get("function", {})
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        parsed.append((fn.get("name"), args))
    return parsed


def run_arm(arm, model, config, transcript, keys):
    """Returns dict: raw_calls, prompt_tokens, latency_ms, syntax_failure, error."""
    base = {"raw_calls": [], "prompt_tokens": None, "latency_ms": None,
            "syntax_failure": False, "error": None}

    if arm == "groq-tools":
        payload = {
            "model": model, "tools": config["tools"], "tool_choice": "auto",
            "temperature": 0.1,
            "messages": [{"role": "system", "content": config["systemPrompt"]},
                         {"role": "user", "content": transcript}],
        }
        body, ms, err = post_json(GROQ_URL, keys["groq"], payload)

    elif arm == "groq-json":
        system = config["systemPrompt"] + JSON_MODE_SUFFIX + prose_from_tools(config["tools"])
        payload = {
            "model": model, "response_format": {"type": "json_object"},
            "temperature": 0.1,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": transcript}],
        }
        body, ms, err = post_json(GROQ_URL, keys["groq"], payload)

    elif arm == "openai":
        payload = {
            "model": model, "tools": openai_strict_tools(config["tools"]),
            "tool_choice": "auto",
            "messages": [{"role": "system", "content": config["systemPrompt"]},
                         {"role": "user", "content": transcript}],
        }
        # The gpt-5.6 family reasons by default and rejects function tools
        # on /v1/chat/completions unless reasoning is switched off. Routing
        # is a fast classification, not a thinking task, so 'none' is what
        # we want anyway — reasoning tokens would only add latency to a
        # hold-to-talk loop.
        if model.startswith("gpt-5.6"):
            payload["reasoning_effort"] = "none"
        body, ms, err = post_json(OPENAI_URL, keys["openai"], payload)

    else:
        sys.exit(f"unknown arm {arm}")

    base["latency_ms"] = ms
    if err is not None:
        base["error"] = err[:400]
        # The failure this whole eval exists to measure: the model produced
        # a tool-call wrapper the provider's own parser could not read.
        base["syntax_failure"] = "tool_use_failed" in err
        return base

    base["prompt_tokens"] = (body.get("usage") or {}).get("prompt_tokens")
    message = (body.get("choices") or [{}])[0].get("message", {}) or {}

    if arm == "groq-json":
        content = message.get("content") or ""
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError:
            base["syntax_failure"] = True
            base["error"] = f"unparseable JSON: {content[:200]}"
            return base
        actions = parsed.get("actions")
        if not isinstance(actions, list):
            base["syntax_failure"] = True
            base["error"] = f'no "actions" array: {content[:200]}'
            return base
        base["raw_calls"] = [(a.get("name"), a.get("arguments") or {})
                             for a in actions if isinstance(a, dict)]
    else:
        base["raw_calls"] = parse_tool_calls(message)

    return base


# --------------------------------------------------------------------------
# Normalizing and scoring
# --------------------------------------------------------------------------

def normalize(raw_calls, pane_resolutions, correction=None):
    """Wire-level calls -> the action vocabulary the test set uses, with pane
    strings resolved exactly as AgentRouter.parseAction would resolve them,
    then AgentRouter.correctedSettingsPane applied on top."""
    actions = []
    for name, args in raw_calls:
        mapped = TOOL_TO_ACTION.get(name)
        if mapped is None:
            actions.append({"action": f"UNKNOWN:{name}", "args": args})
            continue
        action_name, arg_map = mapped
        out_args = {}
        for wire_key, test_key in arg_map.items():
            if wire_key in args and args[wire_key] is not None:
                out_args[test_key] = args[wire_key]

        if action_name == "openSystemSetting":
            pane = out_args.get("pane")
            res = pane_resolutions.get(pane or "", {"kind": "fallback"})
            if res["kind"] == "pane":
                out_args["pane"] = res["displayName"]
            elif res["kind"] == "app":
                action_name, out_args = "openApp", {"name": "System Settings"}
            else:
                action_name, out_args = "openSystemSettingsFallback", {}

        actions.append({"action": action_name, "args": out_args})

    # Mirrors AgentRouter.correctedSettingsPane: when the transcript named a
    # pane but the model punted to the Settings app (or the fallback), the
    # catalog's answer wins. Same narrow conditions as the Swift.
    if correction and len(actions) == 1:
        only = actions[0]
        punted = (
            (only["action"] == "openApp"
             and str(only["args"].get("name", "")).lower() == "system settings")
            or only["action"] == "openSystemSettingsFallback"
        )
        if punted:
            return [{"action": "openSystemSetting",
                     "args": {"pane": correction["displayName"]}}]
    return actions


def same_value(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    return str(a).strip().lower() == str(b).strip().lower()


def case_passes(expected, actual):
    if len(expected) != len(actual):
        return False
    for exp, act in zip(expected, actual):
        if exp["action"] != act["action"]:
            return False
        for k, v in (exp.get("args") or {}).items():
            if not same_value(v, (act.get("args") or {}).get(k)):
                return False
    return True


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=["groq-tools", "groq-json", "openai"])
    ap.add_argument("--model", default=None, help="defaults per arm")
    ap.add_argument("--dry-run", action="store_true", help="build payloads, make no API calls")
    ap.add_argument("--limit", type=int, default=None, help="run only the first N cases")
    ap.add_argument("--no-record", action="store_true", help="skip appending to results.md")
    ap.add_argument("--delay", type=float, default=None,
                    help="seconds between calls; defaults to 0.4 for OpenAI, 13 for Groq")
    args = ap.parse_args()

    # Groq's free tier allows 12,000 tokens per minute and a router call
    # costs ~2,400, so roughly five calls per minute is the ceiling. Firing
    # them back to back just produces a run full of 429s that measures
    # nothing. OpenAI's Tier 1 limits are far higher and need no pacing.
    delay = args.delay if args.delay is not None else (0.4 if args.arm == "openai" else 13.0)

    model = args.model or ("gpt-5-nano" if args.arm == "openai" else GROQ_MODEL)
    suite = json.loads(TEST_SET.read_text())
    cases = suite["cases"][: args.limit] if args.limit else suite["cases"]

    print(f"Reading the real prompt + tools out of AgentRouter.swift …")
    config = swift_helper("dump-config")
    print(f"  system prompt: {len(config['systemPrompt'])} chars, {len(config['tools'])} tools")

    if args.dry_run:
        if args.arm == "groq-json":
            print("\n--- JSON-mode system prompt suffix ---")
            print(JSON_MODE_SUFFIX + prose_from_tools(config["tools"]))
        elif args.arm == "openai":
            print("\n--- first OpenAI strict tool ---")
            print(json.dumps(openai_strict_tools(config["tools"])[0], indent=2))
        print(f"\nDry run: {len(cases)} cases would run against {args.arm} / {model}.")
        return

    keys = {}
    if args.arm.startswith("groq"):
        keys["groq"] = read_key("GROQ_API_KEY", "GROQ_API_KEY")
    if args.arm == "openai":
        keys["openai"] = read_key("OPENAI_API_KEY", "OPENAI_API_KEY")

    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO,
                            capture_output=True, text=True).stdout.strip()
    # The harness reads the working tree, not the committed source, so a
    # bare SHA would misdescribe any run made with uncommitted edits — which
    # happened on 2026-08-09 while iterating on the prompt. Mark it.
    dirty = subprocess.run(["git", "status", "--porcelain", "Sources"], cwd=REPO,
                           capture_output=True, text=True).stdout.strip()
    if dirty:
        commit += "+dirty"
        print(f"  note: Sources/ has uncommitted changes — recording as {commit}")

    print(f"\nRunning {len(cases)} cases — arm={args.arm} model={model} commit={commit}\n")
    results, pane_strings = [], set()
    for i, case in enumerate(cases, 1):
        r = run_arm(args.arm, model, config, case["transcript"], keys)
        for name, cargs in r["raw_calls"]:
            if name == "open_system_setting" and cargs.get("pane"):
                pane_strings.add(cargs["pane"])
        results.append((case, r))
        flag = "ERR " if r["error"] else "    "
        print(f"  {i:>2}/{len(cases)} {flag}{case['id']}")
        if i < len(cases):
            time.sleep(delay)

    print("\nResolving pane strings through the real SettingsPaneCatalog …")
    pane_resolutions = swift_helper("resolve-panes", "\n".join(sorted(pane_strings))) \
        if pane_strings else {}
    corrections = swift_helper("pane-phrases", "\n".join(c["transcript"] for c in cases))

    passed, syntax_failures, other_errors = 0, 0, 0
    tokens, latencies, failures = [], [], []
    for case, r in results:
        actual = normalize(r["raw_calls"], pane_resolutions,
                           corrections.get(case["transcript"]))
        ok = (not r["error"]) and case_passes(case["expect"], actual)
        if ok:
            passed += 1
        else:
            failures.append((case, r, actual))
        if r["syntax_failure"]:
            syntax_failures += 1
        elif r["error"]:
            other_errors += 1
        if r["prompt_tokens"]:
            tokens.append(r["prompt_tokens"])
        if r["latency_ms"]:
            latencies.append(r["latency_ms"])

    n = len(results)
    acc = passed / n * 100 if n else 0
    syn = syntax_failures / n * 100 if n else 0
    med_tok = int(statistics.median(tokens)) if tokens else 0
    med_lat = int(statistics.median(latencies)) if latencies else 0

    print(f"\n{'='*64}\n{args.arm} / {model} @ {commit}\n{'='*64}")
    print(f"  action accuracy      {passed}/{n}  ({acc:.0f}%)")
    print(f"  syntax failures      {syntax_failures}/{n}  ({syn:.0f}%)")
    print(f"  other errors         {other_errors}/{n}")
    print(f"  median prompt tokens {med_tok}")
    print(f"  median latency       {med_lat} ms")

    if failures:
        print(f"\n--- {len(failures)} failing cases ---")
        for case, r, actual in failures:
            print(f"\n  [{case['id']}] {case['transcript']!r}")
            print(f"    expected: {json.dumps(case['expect'])}")
            if r["error"]:
                print(f"    error:    {r['error'][:220]}")
            else:
                print(f"    actual:   {json.dumps(actual)}")

    # A run where nothing reached the model measures the harness, not the
    # arm. Recording it as 0% accuracy would put a row in the results table
    # that reads like a real result and isn't — happened once on 2026-08-08
    # with a truncated API key.
    every_case_errored = n > 0 and all(r["error"] for _, r in results)
    if every_case_errored:
        print("\nEvery case errored before reaching the model — not recording this run.")

    if not args.no_record and not every_case_errored:
        row = (f"| {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC} | `{commit}` | "
               f"{args.arm} | `{model}` | {passed}/{n} ({acc:.0f}%) | "
               f"{syntax_failures} ({syn:.0f}%) | {med_tok} | {med_lat} ms |")
        if not RESULTS.exists():
            RESULTS.write_text(
                "# Router eval results\n\nAppend-only. One row per run. See "
                "[README.md](README.md) for what the metrics mean and the rules "
                "for changing the test set.\n\n"
                "| When | Commit | Arm | Model | Accuracy | Syntax failures | "
                "Median tokens | Median latency |\n|---|---|---|---|---|---|---|---|\n"
            )
        with RESULTS.open("a") as f:
            f.write(row + "\n")
        print(f"\nAppended to {RESULTS.relative_to(REPO)}")


if __name__ == "__main__":
    main()
