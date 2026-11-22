# Base pinned to the python:3.12-slim digest (resolved 2026-07-01):
#   python:3.12-slim (digest: PY_BASE_DIGEST in docker-compose.yml / versions.lock)
# Re-resolve and bump deliberately — never track a floating tag in a shipped Kit.
# PY_BASE_DIGEST is supplied by docker-compose.yml (build.args); no default here on purpose.
ARG PY_BASE_DIGEST
FROM python:3.12-slim@${PY_BASE_DIGEST}
# Redeclared after FROM so the label can use it. `aetulla update` reads this label to find
# dependents that were built on an older shared base (web-extractor + tts share PY_BASE_DIGEST).
ARG PY_BASE_DIGEST
LABEL aetulla.base-digest="${PY_BASE_DIGEST}"

WORKDIR /app

# trafilatura needs libxml2/libxslt at runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2 libxslt1.1 \
    && rm -rf /var/lib/apt/lists/*

# Playwright client version comes from versions.env (must equal the server).
ARG PLAYWRIGHT_VERSION
ENV PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION}
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt "playwright==${PLAYWRIGHT_VERSION:?build arg}"

COPY main.py .

EXPOSE 8000

# Single worker — Playwright connection is per-process and we have light load
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
