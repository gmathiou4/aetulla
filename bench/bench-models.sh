#!/usr/bin/env bash
# Benchmark Ollama models on Yorgos's RTX 5070
# v2 — Updated fleet, 180s per-prompt timeout to prevent thinking-spiral runaways

set -euo pipefail

MODELS=(
  "qwen3.5:9b"
  "qwen2.5:14b-instruct"
  "qwen2.5-coder:14b"
  "deepseek-r1:14b"
  "qwen3.5:35b-a3b"
)

declare -A PROMPTS=(
  [factual]="In one sentence, what is Apache Kafka used for?"
  [code]="Write a Python function that reads a CSV file and returns rows where the 'status' column equals 'active'. No explanation, just code."
  [reasoning]="A train leaves Prague at 14:00 going 80 km/h. Another leaves Brno at 14:30 going 100 km/h toward Prague. They are 200 km apart. At what time do they meet? Show your reasoning briefly."
)

# Per-prompt hard timeout — anything beyond this gets killed
TIMEOUT_S=180

OUT="$HOME/ai-stack/bench-results-$(date +%Y%m%d-%H%M%S).txt"
echo "Benchmark v2 started: $(date -Iseconds)" | tee "$OUT"
echo "Timeout per prompt: ${TIMEOUT_S}s" | tee -a "$OUT"
echo "Output file: $OUT"
echo

for model in "${MODELS[@]}"; do
  echo "==================================================" | tee -a "$OUT"
  echo "MODEL: $model" | tee -a "$OUT"
  echo "==================================================" | tee -a "$OUT"

  # Pre-warm
  echo "[warming up...]"
  timeout 60 curl -sS -X POST http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"10m\"}" \
    > /dev/null || echo "[warmup timed out, proceeding anyway]"

  for category in factual code reasoning; do
    prompt="${PROMPTS[$category]}"
    echo
    echo "--- $category ---" | tee -a "$OUT"
    echo "Q: $prompt" | tee -a "$OUT"

    # Call Ollama with hard timeout
    response=$(timeout "$TIMEOUT_S" curl -sS -X POST http://localhost:11434/api/generate \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg m "$model" --arg p "$prompt" \
            '{model:$m, prompt:$p, stream:false, keep_alive:"10m"}')" || echo "TIMEOUT")

    if [ "$response" = "TIMEOUT" ] || [ -z "$response" ]; then
      echo "A: ⏱️ TIMEOUT after ${TIMEOUT_S}s — model did not return" | tee -a "$OUT"
      echo "📊 — (timed out)" | tee -a "$OUT"
      continue
    fi

    answer=$(echo "$response" | jq -r '.response // "PARSE_ERROR"')
    eval_count=$(echo "$response" | jq -r '.eval_count // 0')
    eval_duration_ns=$(echo "$response" | jq -r '.eval_duration // 1')
    total_duration_ns=$(echo "$response" | jq -r '.total_duration // 1')

    tps=$(echo "scale=1; $eval_count * 1000000000 / $eval_duration_ns" | bc)
    total_s=$(echo "scale=2; $total_duration_ns / 1000000000" | bc)

    echo "A: $answer" | tee -a "$OUT"
    echo "📊 ${eval_count} tokens | ${tps} tok/s | total ${total_s}s" | tee -a "$OUT"
  done

  # Unload model after testing
  curl -sS -X POST http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"prompt\":\"\",\"keep_alive\":0}" \
    > /dev/null
  echo
done

echo "==================================================" | tee -a "$OUT"
echo "Done. Full results saved to: $OUT" | tee -a "$OUT"
