#!/usr/bin/env python3
"""TTS timing + TTS->STT round-trip check (stdlib only).

  python3 bench/tts_roundtrip.py --runs 5            # synthesis timing only (needs tts)
  python3 bench/tts_roundtrip.py --runs 5 --roundtrip  # + feed audio to stt, compare to input text

Round-trip match is reported two ways: strict (case/punctuation-insensitive) and
accent-insensitive (Greek tonos stripped, final sigma folded) — the second separates
"wrong word" from "wrong accent mark".
"""
import argparse, json, statistics, unicodedata, urllib.request, uuid, re

TEXTS = {
    ("en", "short"): "What is the weather like today?",
    ("en", "long"): ("Yesterday I went to the market to buy fresh fruit and vegetables, and then I met an old "
                     "friend I had not seen in many years, so we sat down in a small cafe and talked for hours."),
    ("el", "short"): "Τι ώρα είναι τώρα;",
    ("el", "long"): ("Σήμερα το πρωί πήγα στην αγορά για να αγοράσω φρέσκα φρούτα και λαχανικά, και μετά "
                     "συνάντησα έναν παλιό φίλο που δεν είχα δει εδώ και πολλά χρόνια, οπότε καθίσαμε σε ένα "
                     "καφενείο και μιλήσαμε για ώρες."),
}


def synth(base, text, lang, speed=1.0):
    req = urllib.request.Request(f"{base}/synthesize", json.dumps({"text": text, "language": lang, "speed": speed}).encode(),
                                 {"Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=120)
    return r.read(), {k.lower(): v for k, v in r.getheaders()}


def stt(base, wav, lang):
    b = uuid.uuid4().hex
    body = (f'--{b}\r\nContent-Disposition: form-data; name="language"\r\n\r\n{lang}\r\n'
            f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode() \
           + wav + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"{base}/transcribe", body, {"Content-Type": f"multipart/form-data; boundary={b}"})
    return json.loads(urllib.request.urlopen(req, timeout=120).read())


def norm(s, strip_accents=False):
    s = s.lower().replace("ς", "σ")
    if strip_accents:
        s = "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")
    return re.sub(r"[^\w\s]", " ", s).split()


def wer(ref, hyp):  # word-level Levenshtein / len(ref)
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[-1] / max(len(ref), 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tts", default="http://127.0.0.1:8020")
    ap.add_argument("--stt", default="http://127.0.0.1:8010")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--roundtrip", action="store_true")
    ap.add_argument("--trials", type=int, default=5, help="round-trip trials per text")
    a = ap.parse_args()

    print(f"{'lang':4} {'len':5} {'chars':>5} {'audio_s':>8} {'synth_ms(med)':>14} {'min':>6} {'max':>6} {'RTF(med)':>9}")
    wavs = {}
    for (lang, kind), text in TEXTS.items():
        synth(a.tts, text, lang)  # one discarded call so every row is steady-state
        ms, rtf = [], []
        for _ in range(a.runs):
            wav, h = synth(a.tts, text, lang)
            ms.append(float(h["x-synth-ms"])); rtf.append(float(h["x-rtf"])); audio_s = float(h["x-audio-seconds"])
        wavs[(lang, kind)] = wav
        print(f"{lang:4} {kind:5} {len(text):5d} {audio_s:8.2f} {statistics.median(ms):14.1f} {min(ms):6.1f} {max(ms):6.1f} {statistics.median(rtf):9.3f}")

    if a.roundtrip:
        # Piper is stochastic (noise_scale), so one sample per phrase misleads: synthesize fresh each trial.
        print(f"\nround trip: text -> TTS -> STT (forced language) -> compare, {a.trials} fresh trials per text")
        for (lang, kind), text in TEXTS.items():
            w_s, w_a, ex_s, ex_a, outs = [], [], 0, 0, []
            for _ in range(a.trials):
                wav, h = synth(a.tts, text, lang)
                r = stt(a.stt, wav, lang)
                ref, hyp = norm(text), norm(r["text"])
                ref_na, hyp_na = norm(text, True), norm(r["text"], True)
                w_s.append(wer(ref, hyp)); w_a.append(wer(ref_na, hyp_na))
                ex_s += ref == hyp; ex_a += ref_na == hyp_na; outs.append(r["text"])
            print(f"[{lang}/{kind}] voice={h['x-voice']} mean WER strict={statistics.mean(w_s):.3f} accent-insens={statistics.mean(w_a):.3f}"
                  f" | exact {ex_s}/{a.trials} strict, {ex_a}/{a.trials} accent-insens")
            print(f"   in : {text}")
            for o in outs: print(f"   out: {o}")


if __name__ == "__main__":
    main()
