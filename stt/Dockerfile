# STT service: faster-whisper (CTranslate2) on GPU.
# Base: CUDA 12.8 is the first release with Blackwell (sm_120) support; pinned to digest.
# The CTranslate2 wheel ships no native sm_120 kernels, so the first run JIT-compiles PTX
# (~15 s). CUDA_CACHE_PATH points at a named volume so that cost is paid once, not per container.
FROM nvidia/cuda:12.8.0-base-ubuntu24.04@sha256:e778509d37d66475120929671500377524f7278478ba08131b07ef3ffcc0dce0

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Non-root user + pre-created cache dirs. Docker copies image-dir ownership into an empty
# named volume on first mount, so the volumes below come up owned by `stt`, not root.
RUN useradd --uid 10001 --create-home stt \
 && mkdir -p /cache/hf /cache/cuda \
 && chown -R stt:stt /cache

RUN python3 -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# pip-provided cuBLAS/cuDNN are not on the default loader path.
ENV LD_LIBRARY_PATH=/opt/venv/lib/python3.12/site-packages/nvidia/cublas/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cudnn/lib \
    PATH=/opt/venv/bin:$PATH \
    HF_HOME=/cache/hf \
    CUDA_CACHE_PATH=/cache/cuda \
    CUDA_CACHE_MAXSIZE=2147483648 \
    PYTHONUNBUFFERED=1

COPY app.py /app/app.py
USER stt
WORKDIR /app
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
