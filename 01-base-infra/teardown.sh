#!/usr/bin/env bash
#
# Delete the EKS Auto Mode cluster and its eksctl-managed VPC/IAM resources.
#
# Usage:
#   ./teardown.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cluster-config.yaml"

echo ">> Deleting cluster defined in ${CONFIG_FILE} ..."
echo "   NOTE: any EFS filesystems / EBS volumes you created manually are NOT"
echo "   deleted by this command. Remove them separately to avoid charges."
eksctl delete cluster -f "$CONFIG_FILE" --disable-nodegroup-eviction

echo ">> Teardown complete."
