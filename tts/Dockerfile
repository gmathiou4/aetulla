# TTS service: Piper (ONNX, CPU). Voices are NOT baked in: they are downloaded into the
# /voices named volume on first start and sha256-verified against voices.json.
# PY_BASE_DIGEST is supplied by docker-compose.yml (build.args); no default here on purpose.
ARG PY_BASE_DIGEST
FROM python:3.12-slim@${PY_BASE_DIGEST}
# Redeclared after FROM so the label can use it. `aetulla update` reads this label to find
# dependents that were built on an older shared base (web-extractor + tts share PY_BASE_DIGEST).
ARG PY_BASE_DIGEST
LABEL aetulla.base-digest="${PY_BASE_DIGEST}"

# Non-root user; /voices pre-created so the named volume comes up owned by `tts`, not root.
RUN useradd --uid 10002 --create-home tts \
 && mkdir -p /voices \
 && chown tts:tts /voices

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY app.py voices.json /app/
USER tts
WORKDIR /app
ENV PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
