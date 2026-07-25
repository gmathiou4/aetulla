#!/usr/bin/env bash
# Idempotent Ollama model pull. Required models block install completion;
# optional models are offered but skippable.
set -euo pipefail

REQUIRED_MODELS=("qwen2.5:14b-instruct" "nomic-embed-text")
OPTIONAL_MODELS=("qwen2.5-coder:14b" "deepseek-r1:14b")

model_present() {
    # `ollama list` shows untagged pulls with an implicit ":latest" suffix
    # (e.g. "nomic-embed-text" pulled with no tag shows as
    # "nomic-embed-text:latest") — check both forms, fixed-string exact match.
    local model="$1"
    local names
    names=$(ollama list 2>/dev/null | awk '{print $1}')
    grep -qFx "$model" <<<"$names" || grep -qFx "${model}:latest" <<<"$names"
}

pull_if_missing() {
    local model="$1"
    if model_present "$model"; then
        echo "✓ ${model} already present, skipping"
    else
        echo "→ pulling ${model} ..."
        ollama pull "$model"
    fi
}

echo "=== Required models ==="
for m in "${REQUIRED_MODELS[@]}"; do
    pull_if_missing "$m"
done

if [[ "${PULL_OPTIONAL:-ask}" == "ask" ]] && [[ -t 0 ]]; then
    echo ""
    echo "=== Optional models ==="
    for m in "${OPTIONAL_MODELS[@]}"; do
        read -r -p "Pull optional model ${m}? [y/N] " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            pull_if_missing "$m"
        fi
    done
elif [[ "${PULL_OPTIONAL:-ask}" == "all" ]]; then
    echo ""
    echo "=== Optional models (PULL_OPTIONAL=all) ==="
    for m in "${OPTIONAL_MODELS[@]}"; do
        pull_if_missing "$m"
    done
fi

echo ""
echo "=== Verifying required models present ==="
missing=0
for m in "${REQUIRED_MODELS[@]}"; do
    if ! model_present "$m"; then
        echo "✗ MISSING: ${m}"
        missing=1
    fi
done
if [[ "$missing" -eq 1 ]]; then
    echo "ERROR: required models missing after pull attempt." >&2
    exit 1
fi
echo "✓ all required models present"
