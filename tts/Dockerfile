# TTS service: Piper (ONNX, CPU). Voices are NOT baked in: they are downloaded into the
# /voices named volume on first start and sha256-verified against voices.json.
FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf

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
