# ---------------------------------------------------------------------------
# Presidio Sensitivity Worker — Container Image
#
# Security requirements:
#   - Non-root user (uid 1000)
#   - No bash; sh is acceptable
#   - Minimal image surface (python:3.11-slim)
#   - No secrets baked in — all config via env vars at runtime
#   - CPU/memory limits are enforced by Helm, not here
# ---------------------------------------------------------------------------

FROM python:3.11-slim

# -- Non-root user ----------------------------------------------------------
RUN groupadd --gid 1000 worker && \
    useradd --uid 1000 --gid worker --no-create-home --shell /usr/sbin/nologin worker

# -- Working directory -------------------------------------------------------
WORKDIR /app

# -- Dependencies ------------------------------------------------------------
# Copy requirements before source so Docker layer cache is effective.
COPY requirements.txt ./

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# -- Application source ------------------------------------------------------
COPY *.py ./

# -- Ownership ---------------------------------------------------------------
RUN chown -R worker:worker /app

# -- Switch to non-root user -------------------------------------------------
USER worker

# -- Expose port -------------------------------------------------------------
EXPOSE 8080

# -- Health check ------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

# -- Entrypoint --------------------------------------------------------------
# Use exec form to ensure proper signal handling and no shell wrapping.
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
