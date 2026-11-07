# =============================================================================
#  Image Builder front end - container image
# =============================================================================
#  Not how this is deployed on the current cluster: there is no registry there,
#  so kubernetes/workloads/web-frontend.yaml mounts the same files from a
#  ConfigMap. This image is for anywhere that does have one, and for running
#  the application the same way locally.
#
#      docker build -t aria-image-builder-web web
#      docker run --rm -p 8080:8080 \
#          -v "$HOME/.kube:/home/app/.kube:ro" \
#          aria-image-builder-web
#
#  The kubeconfig mount is what lets it talk to the cluster from a workstation.
#  On a cluster, the service account does that instead and no mount is needed.
# =============================================================================
FROM python:3.14-slim

# No .pyc files in a read-only filesystem, and logs that appear immediately
# rather than when a buffer happens to fill.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FLASK_HOST=0.0.0.0 \
    FLASK_PORT=8080

WORKDIR /app

# Dependencies first, so a change to the application does not reinstall them.
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# The application, explicitly - not `COPY . .`, which would drag the tests and
# this Dockerfile into the image.
COPY app.py config.py kube.py services.py quantities.py k8stime.py \
     naming.py runs.py projects.py pages.py api.py ./
COPY templates/ ./templates/
COPY static/ ./static/

# A fixed, unprivileged uid. Nothing here writes to disk, so the user needs no
# home directory beyond the one kubectl looks in for a kubeconfig.
RUN useradd --system --uid 10001 --no-create-home appuser

# The one directory the client reads a kubeconfig from, empty by default. On a
# cluster the mounted service account is used instead and this is never read.
RUN mkdir -p /home/app/.kube && chown -R 10001 /home/app
ENV HOME=/home/app
USER 10001

EXPOSE 8080

# /healthz answers without touching the cluster, which is the whole point of
# keeping it separate from /api/health.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=4).status == 200 else 1)"]

CMD ["python", "app.py"]
