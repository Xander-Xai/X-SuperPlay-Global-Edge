FROM python:3.12-slim@sha256:2fe5997d249a808b8eeea52c58a1dbffbba28754dc11699ef5c029f2d818ce79

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN addgroup --system --gid 10001 edgehealth \
    && adduser --system --uid 10001 --ingroup edgehealth --no-create-home edgehealth

# Keep one canonical dependency manifest. The API manifest references the
# existing edge-health-agent requirements without duplicating its entries.
COPY services/edge-health-api/requirements.txt /tmp/build/services/edge-health-api/requirements.txt
COPY tools/edge-health-agent/requirements.txt /tmp/build/tools/edge-health-agent/requirements.txt
RUN python -m pip install --no-cache-dir --requirement /tmp/build/services/edge-health-api/requirements.txt \
    && rm -rf /tmp/build

COPY services/edge-health-api/app.py /app/services/edge-health-api/app.py
COPY services/edge-health-api/models.py /app/services/edge-health-api/models.py
COPY services/edge-health-api/identity/*.py /app/services/edge-health-api/identity/
COPY services/edge-health-api/metrics/*.py /app/services/edge-health-api/metrics/
COPY services/edge-health-api/routes/*.py /app/services/edge-health-api/routes/
COPY services/edge-health-api/runtime/*.py /app/services/edge-health-api/runtime/
COPY tools/edge-health-agent/probe.py /app/tools/edge-health-agent/probe.py
COPY tools/edge-health-agent/alert/*.py /app/tools/edge-health-agent/alert/
COPY tools/edge-health-agent/evidence/*.py /app/tools/edge-health-agent/evidence/

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/v1/node/metadata', timeout=2).read()"]

ENTRYPOINT ["python", "services/edge-health-api/app.py"]
CMD ["--host", "0.0.0.0", "--port", "8080", "--evidence-root", "/data/evidence", "--identity-config", "/run/x-superplay/node.yaml"]
