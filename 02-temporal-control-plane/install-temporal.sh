#!/usr/bin/env bash
#
# Install the Temporal control plane into Kubernetes against an external
# Aurora PostgreSQL cluster, using the official temporalio/temporal Helm chart.
#
# Chart docs: https://github.com/temporalio/helm-charts/blob/main/README.md#install-with-postgresql
#
# Prereqs:
#   * kubectl context pointed at the target cluster
#   * helm 3.x or 4.x installed (helm 4 is fine — v2 chart format is compatible)
#   * Aurora cluster up, with TWO empty databases pre-created:  temporal, temporal_visibility
#   * The DB user below has privileges on both databases
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment, or edit here.
# ---------------------------------------------------------------------------
RELEASE="${RELEASE:-temporal}"
NAMESPACE="${NAMESPACE:-temporal}"
CHART_VERSION="${CHART_VERSION:-1.5.0}"          # latest stable release of the chart
CHART_REPO="${CHART_REPO:-https://go.temporal.io/helm-charts}"
VALUES_FILE="${VALUES_FILE:-values.aurora-postgres.yaml}"
SECRET_NAME="${SECRET_NAME:-temporal-db-passwords}"

# DB password: must be supplied via env, not stored on disk.
#   export TEMPORAL_DB_PASSWORD='...'
: "${TEMPORAL_DB_PASSWORD:?Set TEMPORAL_DB_PASSWORD to the Aurora DB password before running}"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v helm >/dev/null    || { echo "helm not found"; exit 1; }

echo ">> helm version: $(helm version --short 2>/dev/null || helm version)"

if grep -q 'REPLACE_' "${VALUES_FILE}"; then
  echo "ERROR: ${VALUES_FILE} still contains REPLACE_ placeholders."
  echo "       Set the Aurora writer endpoint and DB user before installing."
  grep -n 'REPLACE_' "${VALUES_FILE}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Namespace + DB password secret (referenced by both stores via existingSecret)
# ---------------------------------------------------------------------------
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal=password="${TEMPORAL_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# Install / upgrade Temporal
# ---------------------------------------------------------------------------
# --timeout 900s: the schema pre-install hook (setup-schema + update-schema)
# must finish before the server pods start.
helm upgrade --install "${RELEASE}" temporal \
  --repo "${CHART_REPO}" \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --timeout 900s \
  --wait

echo
echo ">> Done. Check rollout:"
echo "     kubectl -n ${NAMESPACE} get pods"
echo ">> Schema job logs (if troubleshooting):"
echo "     kubectl -n ${NAMESPACE} logs job/${RELEASE}-schema --all-containers"
echo ">> Open the Web UI:"
echo "     kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-web 8080:8080"
echo "     open http://localhost:8080"
