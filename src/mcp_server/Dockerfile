# ---------------------------------------------------------------------------
# MCP Presidio Sensitivity Server — Container Image
#
# Security requirements:
#   - Non-root user (uid 1001 — distinct from worker uid 1000)
#   - No bash; sh is acceptable
#   - Minimal image surface (python:3.11-slim)
#   - No secrets baked in — all config via env vars at runtime
#   - CPU/memory limits are enforced by Helm, not here
# ---------------------------------------------------------------------------

FROM python:3.11-slim

# -- Non-root user ----------------------------------------------------------
# uid 1001 is distinct from the worker (uid 1000) to avoid shared identity
# if both containers ever run on the same node with shared UID namespacing.
RUN groupadd --gid 1001 mcpserver && \
    useradd --uid 1001 --gid mcpserver --no-create-home --shell /usr/sbin/nologin mcpserver

# -- Working directory -------------------------------------------------------
WORKDIR /app

# -- Dependencies ------------------------------------------------------------
# requirements.lock.txt is the pip-compiled exact-version lock file.
# requirements.txt is the human-maintained constraints file (kept for
# pip-compile regeneration — not used at build time).
# Regenerate the lock file: docker run --rm -v $(pwd):/work python:3.11-slim \
#   sh -c 'pip install -q pip-tools && cd /work && pip-compile --no-header \
#          --strip-extras -o requirements.lock.txt requirements.txt'
COPY requirements.txt requirements.lock.txt ./

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.lock.txt

# -- Application source ------------------------------------------------------
COPY *.py ./
COPY auth/ ./auth/
COPY authorization/ ./authorization/
COPY tools/ ./tools/
COPY backend/ ./backend/
COPY observability/ ./observability/

# -- Ownership ---------------------------------------------------------------
RUN chown -R mcpserver:mcpserver /app

# -- Switch to non-root user -------------------------------------------------
USER mcpserver

# -- Expose port -------------------------------------------------------------
EXPOSE 8000

# -- Health check ------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

# -- Entrypoint --------------------------------------------------------------
# Use exec form to ensure proper signal handling and no shell wrapping.
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
