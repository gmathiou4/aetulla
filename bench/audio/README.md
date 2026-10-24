# Benchmark audio fixtures

Synthetic speech generated with Piper (`piper-tts 1.8.0`). Not human speech —
they validate the pipeline and give a known reference text, not real-world
ASR accuracy (that is Step 2).

| File | Voice | Reference text |
|------|-------|----------------|
| `en_01.wav` | `en_US-lessac-medium` | Hello, can you tell me what the capital of France is, and how far it is from Berlin? |
| `el_01.wav` | `el_GR-rapunzelina-low` | Καλημέρα, μπορείς να μου πεις ποια είναι η πρωτεύουσα της Ελλάδας και πόσο μακριά είναι από την Κρήτη; |

Regenerate (CPU only, no root-owned files):

```bash
docker run --rm --user $(id -u):$(id -g) -v "$PWD/tmp_tts":/work python:3.12-slim bash -c '
  export HOME=/work; python -m venv /work/venv && . /work/venv/bin/activate
  pip install -q piper-tts==1.8.0
  python -m piper.download_voices --download-dir /work/voices en_US-lessac-medium el_GR-rapunzelina-low
  python -m piper -m en_US-lessac-medium --data-dir /work/voices -f /work/en_01.wav -- "<text>"'
```
