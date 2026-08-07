# ──────────────────────────────────────────────────────────────────────────────
# Dockerfile for the CreditGate FCC TEE Python handler
#
# Pattern: pin on the upstream flare-ai-kit two-stage build →
#   Stage 1 "builder": uv:python3.12-bookworm-slim to compile a clean venv
#   Stage 2 "runtime": python:3.12-slim-bookworm run as a non-root user
#
# The image is built reproducibly (no host mounts, no .git, pinned deps) so the
# published digest can be pinned in GCP Confidential Space and verified against
# the Git source for the TEE attestation check.
#
# Local build/run:
#   docker build -t creditgate-fcc-tee -f fcc-handler/Dockerfile .
#   docker run --rm -p 8080:8080 --env-file fcc-handler/.env creditgate-fcc-tee
#
# Confidential Space deploy: see ./deploy-tee.sh
# ──────────────────────────────────────────────────────────────────────────────

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0 \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

# ── 1. System deps (curl for the GCP metadata token fetch, no compilers kept) ──
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

# ── 2. Lock the dependencies into the venv first (cacheable layer) ──────────
# We declare deps inline via a minimal pyproject so we don't need a uv.lock.
# All deps are mainstream EVM packages, all wheels (no build-time compilers).
COPY fcc-handler/pyproject.toml ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --no-dev --no-editable --no-install-project

# ── 3. Copy the handler source and install the project into the venv ────────
COPY fcc-handler/credit_tee_handler.py ./
COPY fcc-handler/README.md ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --no-dev --no-editable

# Clean caches — keep the built image reproducible and small.
RUN rm -rf /root/.cache/uv /root/.cache/pip

# ───────────────────────── runtime stage ──────────────────────────────────────
FROM python:3.12-slim-bookworm AS runtime

# Runtime system deps: curl for the Confidential Space metadata token fetch
# inside the TEE; nothing else.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

ENV PIP_NO_CACHE_DIR=1 \
    UV_PYTHON_DOWNLOADS=0 \
    PYTHONPATH="/app:$PYTHONPATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# ── Create a non-root user so the enclave process drops privileges ─────────
RUN groupadd -r app && \
    useradd -r -g app -d /nonexistent -s /usr/sbin/nologin app

# Pull the full built application (venv + source) from the builder stage.
COPY --from=builder --chown=app:app /app /app

WORKDIR /app
ENV PATH="/app/.venv/bin:$PATH"

USER app

# Health probe — the Confidential Space runtime hits this.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

# Port the proxy connects to (set in Confidential Space metadata, defaults to 8080).
EXPOSE 8080

# Default command: run the WSGI server defined in credit_tee_handler.main()
CMD ["python", "/app/credit_tee_handler.py"]
