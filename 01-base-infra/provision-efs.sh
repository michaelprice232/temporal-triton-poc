#!/usr/bin/env bash
#
# Provision a basic EFS file system for the temporal-eks cluster so pods can
# share files (ReadWriteMany). This:
#   1. discovers the cluster's VPC + private subnets,
#   2. creates a security group allowing NFS (2049) from within the VPC,
#   3. creates an encrypted EFS file system,
#   4. adds a mount target in each private subnet,
#   5. creates a dynamic-provisioning StorageClass (efs-sc).
#
# Requires: awscli v2 (with creds), kubectl (pointed at the cluster), jq.
# The aws-efs-csi-driver add-on must already be installed (it is, via
# cluster-config.yaml).
#
# Usage:
#   ./provision-efs.sh
#
set -euo pipefail

CLUSTER_NAME="temporal-eks"
REGION="eu-west-2"
EFS_NAME="temporal-eks-efs"
SG_NAME="temporal-eks-efs-sg"

for tool in aws kubectl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found on PATH." >&2; exit 1; }
done

echo ">> Looking up cluster VPC..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
  --query 'Vpcs[0].CidrBlock' --output text)
echo "   VPC: $VPC_ID ($VPC_CIDR)"

echo ">> Finding private subnets (tagged by eksctl)..."
# Word-split the tab/space-separated IDs into an array (bash 3.2-compatible;
# macOS ships bash 3.2, which has no `mapfile`).
PRIVATE_SUBNETS=($(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text))
if [ "${#PRIVATE_SUBNETS[@]}" -eq 0 ]; then
  echo "ERROR: no private subnets found in $VPC_ID." >&2
  exit 1
fi
echo "   Private subnets: ${PRIVATE_SUBNETS[*]}"

echo ">> Ensuring EFS security group ($SG_NAME)..."
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG_NAME" \
    --description "NFS access to EFS for $CLUSTER_NAME" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 2049 --cidr "$VPC_CIDR" >/dev/null
  echo "   Created SG $SG_ID (allow tcp/2049 from $VPC_CIDR)"
else
  echo "   Reusing SG $SG_ID"
fi

echo ">> Ensuring EFS file system ($EFS_NAME)..."
FS_ID=$(aws efs describe-file-systems --region "$REGION" \
  --query "FileSystems[?Name=='$EFS_NAME'].FileSystemId | [0]" --output text)
if [ "$FS_ID" = "None" ] || [ -z "$FS_ID" ]; then
  FS_ID=$(aws efs create-file-system --region "$REGION" \
    --encrypted \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --tags "Key=Name,Value=$EFS_NAME" \
    --query 'FileSystemId' --output text)
  echo "   Created EFS $FS_ID; waiting for it to become available..."
  until [ "$(aws efs describe-file-systems --file-system-id "$FS_ID" --region "$REGION" \
        --query 'FileSystems[0].LifeCycleState' --output text)" = "available" ]; do
    sleep 5
  done
else
  echo "   Reusing EFS $FS_ID"
fi

echo ">> Ensuring a mount target in each private subnet..."
EXISTING_MT_SUBNETS=$(aws efs describe-mount-targets --file-system-id "$FS_ID" --region "$REGION" \
  --query 'MountTargets[].SubnetId' --output text)
for subnet in "${PRIVATE_SUBNETS[@]}"; do
  if echo "$EXISTING_MT_SUBNETS" | grep -qw "$subnet"; then
    echo "   Mount target already exists in $subnet"
  else
    aws efs create-mount-target --region "$REGION" \
      --file-system-id "$FS_ID" --subnet-id "$subnet" \
      --security-groups "$SG_ID" >/dev/null
    echo "   Created mount target in $subnet"
  fi
done

echo ">> Applying StorageClass 'efs-sc' (dynamic access-point provisioning)..."
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $FS_ID
  directoryPerms: "700"
  basePath: "/dynamic"
  ensureUniqueDirectory: "false"
EOF

cat <<EOF

>> EFS ready.
   File system: $FS_ID
   StorageClass: efs-sc

   To share files across pods, have every pod use ONE PVC (ReadWriteMany).
   See efs-shared-example.yaml for a working PVC + two pods writing to it:

     kubectl apply -f efs-shared-example.yaml
EOF
