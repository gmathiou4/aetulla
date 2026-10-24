#!/usr/bin/env python3
"""Does the model emit a valid tool call through Ollama's tools API? (decides 'brain' vs 'Greek specialist')

  python3 bench/tool_call_test.py --models qwen3:8b,hf.co/ilsp/Llama-Krikri-8B-Instruct-GGUF:Q4_K_M --runs 5

Per language: 5x a prompt that needs get_time (expect a get_time call with a string timezone),
5x a control prompt that does NOT need a tool (expect no call), and for each valid call a
second turn feeding the tool result back (expect a natural reply that contains the time).
"""
import argparse, json, urllib.error
from common import OLLAMA, post_json, unload_all

TOOLS = [{"type": "function", "function": {
    "name": "get_time", "description": "Get the current local time in a city or IANA timezone.",
    "parameters": {"type": "object", "properties": {"timezone": {"type": "string",
                   "description": "IANA timezone name or city, e.g. Europe/Prague"}}, "required": ["timezone"]}}}]
SYSTEM = "You are a helpful voice assistant. Answer in 1-2 short sentences, in the user's language. Use tools when needed."
PROMPTS = {
    "en": {"tool": "What time is it in Prague right now?", "control": "What is the capital of France?"},
    "el": {"tool": "Τι ώρα είναι τώρα στην Αθήνα;", "control": "Ποια είναι η πρωτεύουσα της Γαλλίας;"},
}
FAKE_TIME = "14:35"


def chat(model, messages, think):
    p = {"model": model, "messages": messages, "tools": TOOLS, "stream": False, "keep_alive": "30m",
         "options": {"temperature": 0.2, "num_ctx": 4096, "num_predict": 200}}
    if think is not None:
        p["think"] = think
    try:
        return post_json(f"{OLLAMA}/api/chat", p)["message"], None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read().decode()[:200]}"


def valid_call(msg):
    calls = (msg or {}).get("tool_calls") or []
    if not calls:
        return None
    f = calls[0]["function"]
    args = f.get("arguments")
    if f.get("name") == "get_time" and isinstance(args, dict) and isinstance(args.get("timezone"), str) and args["timezone"].strip():
        return calls
    return False  # a call was emitted but malformed / wrong function


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--runs", type=int, default=5)
    a = ap.parse_args()
    for model in a.models.split(","):
        unload_all()
        think = False if model.startswith("qwen3") else None  # only qwen3 has a thinking switch
        print(f"\n=== {model} (think={think}) ===")
        for lang, pr in PROMPTS.items():
            ok = bad = none = errs = turn2 = ctl_clean = 0
            sample = None
            for _ in range(a.runs):
                msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": pr["tool"]}]
                m, err = chat(model, msgs, think)
                if err:
                    errs += 1; sample = sample or err; continue
                v = valid_call(m)
                if v:
                    ok += 1; sample = sample or json.dumps(v[0]["function"], ensure_ascii=False)
                    msgs += [m, {"role": "tool", "tool_name": "get_time", "content": FAKE_TIME}]
                    m2, err2 = chat(model, msgs, think)
                    if m2 and FAKE_TIME in (m2.get("content") or "") and not m2.get("tool_calls"):
                        turn2 += 1
                elif v is False:
                    bad += 1; sample = sample or f"malformed: {json.dumps(m.get('tool_calls'), ensure_ascii=False)}"
                else:
                    none += 1; sample = sample or f"no call; content={(m.get('content') or '')[:120]!r}"
                m, err = chat(model, [{"role": "system", "content": SYSTEM}, {"role": "user", "content": pr["control"]}], think)
                if m and not m.get("tool_calls"):
                    ctl_clean += 1
            print(f"[{lang}] valid get_time call {ok}/{a.runs} | malformed {bad} | no call {none} | API errors {errs}"
                  f" | 2nd turn uses result {turn2}/{ok} | control (no tool needed) clean {ctl_clean}/{a.runs}")
            print(f"     sample: {sample}")


if __name__ == "__main__":
    main()
