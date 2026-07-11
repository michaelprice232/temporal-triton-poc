#!/usr/bin/env bash
#
# Provision the EKS Auto Mode cluster defined in cluster-config.yaml.
#
# Prerequisites:
#   - eksctl >= 0.210 (Auto Mode + Pod Identity add-on support)
#   - awscli v2, configured with credentials that can create EKS/VPC/IAM
#   - kubectl
#
# Usage:
#   ./deploy.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cluster-config.yaml"
REGION="eu-west-2"

echo ">> Checking required tools..."
for tool in eksctl aws kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' is not installed or not on PATH." >&2
    exit 1
  fi
done

echo ">> Verifying AWS credentials..."
aws sts get-caller-identity --region "$REGION" >/dev/null

echo ">> Creating cluster from ${CONFIG_FILE} ..."
echo "   (this typically takes 15-25 minutes)"
eksctl create cluster -f "$CONFIG_FILE"

echo ">> Updating local kubeconfig..."
eksctl utils write-kubeconfig -f "$CONFIG_FILE"

echo ">> Installed add-ons:"
eksctl get addons --cluster temporal-eks --region "$REGION" || true

echo ">> Cluster nodes (Auto Mode may show none until a workload is scheduled):"
kubectl get nodes || true

echo ">> Done. Cluster 'temporal-eks' is ready in ${REGION}."
