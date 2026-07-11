# Step 1 — Infrastructure: EKS, Aurora, EFS

Provision the three foundational pieces the rest of the POC sits on:

1. an **EKS Auto Mode** cluster,
2. an **Aurora PostgreSQL Serverless v2** cluster with two empty databases,
3. an **EFS** filesystem with the dynamic `efs-sc` StorageClass.

Region throughout: **eu-west-2 (London)**.

---

## 1a. EKS Auto Mode cluster

Declarative `eksctl` config — Auto Mode manages compute/scaling and block
storage (EBS), and we add the EFS CSI driver add-on (EFS is not part of Auto
Mode).

```bash
./deploy.sh          # ~15-25 min; creates VPC + cluster, writes kubeconfig
kubectl get nodes    # Auto Mode shows nodes once a workload schedules
```

Files:
- [`cluster-config.yaml`](./cluster-config.yaml) — the `ClusterConfig` (Auto Mode, single NAT gateway for cost, `aws-efs-csi-driver` add-on via Pod Identity).
- [`deploy.sh`](./deploy.sh) / [`teardown.sh`](./teardown.sh) — create / destroy.
- [`ebs-sc.yaml`](./ebs-sc.yaml) — optional gp3 default StorageClass (Auto Mode provides the EBS provisioner).

## 1b. EFS + dynamic `efs-sc` StorageClass

Creates the filesystem, a security group allowing NFS (2049) from the VPC, a
mount target per private subnet, and the **dynamic** StorageClass.

```bash
./provision-efs.sh
```

This uses **dynamic provisioning** (`provisioningMode: efs-ap`) throughout — each
PVC gets its own EFS access point automatically. Pods share data by pointing at
the **same PVC** (EFS is ReadWriteMany).

- [`provision-efs.sh`](./provision-efs.sh) — the provisioning script.
- [`efs-shared-example.yaml`](./efs-shared-example.yaml) — sanity check: two pods writing/reading one shared PVC.

```bash
kubectl apply -f efs-shared-example.yaml
kubectl exec efs-reader -- cat /data/out.txt   # sees what efs-writer wrote
kubectl delete -f efs-shared-example.yaml
```

## 1c. Aurora PostgreSQL Serverless v2

> Not scripted in this POC — created via the AWS CLI/console. Commands below are
> a reference. Put it in the **same VPC** as the cluster (or peered) so the
> Temporal pods can reach it, and open **5432** from the node security group.

```bash
REGION=eu-west-2
# 1. Serverless v2 Postgres cluster (min 0.5 ACU keeps POC cost low; raise for real traffic)
aws rds create-db-cluster --region $REGION \
  --db-cluster-identifier temporal-pg \
  --engine aurora-postgresql --engine-version 16.6 \
  --master-username postgres --manage-master-user-password \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=4 \
  --vpc-security-group-ids <sg-allowing-5432> \
  --db-subnet-group-name <cluster-subnet-group>

# 2. A Serverless v2 writer instance
aws rds create-db-instance --region $REGION \
  --db-instance-identifier temporal-pg-1 \
  --db-cluster-identifier temporal-pg \
  --engine aurora-postgresql --db-instance-class db.serverless
```

Then create the **two empty databases** Temporal needs (the Helm chart fills the
schema; it does not create the databases). Connect with `psql` or the RDS Query
Editor and run each separately (Postgres won't `CREATE DATABASE` in a txn block):

```sql
CREATE DATABASE temporal;
CREATE DATABASE temporal_visibility;
```

Confirm TLS enforcement so it matches the Helm values (`tls.enabled: true`):

```sql
SHOW rds.force_ssl;   -- 1 = enforced (our config satisfies it either way)
```

Grab the **writer** endpoint — you'll paste it into step 2:

```bash
aws rds describe-db-clusters --region $REGION \
  --db-cluster-identifier temporal-pg \
  --query 'DBClusters[0].Endpoint' --output text
```

---

## Why these choices

- **EKS Auto Mode** removes nodegroup/Karpenter management for a POC while still
  giving on-demand scaling and instance selection (used later to schedule the
  model-conversion pod onto a high-clock-speed node).
- **Aurora Serverless v2** scales the DB to load and is cheap at idle; Temporal
  is supported on PostgreSQL 13–16.
- **EFS dynamic provisioning** is the simplest way to get ReadWriteMany shared
  storage for the model repository — no static PV/volume-handle wiring.

## Going to production

- Single NAT gateway → `HighlyAvailable` (one per AZ) in `cluster-config.yaml`.
- Raise Aurora `MinCapacity`; don't let it scale to a floor that starves
  connections. Consider a dedicated `temporal` DB user instead of `postgres`.
- Lock the EFS/DB security groups to the node SG rather than the VPC CIDR.

## Teardown

```bash
./teardown.sh    # deletes the cluster + eksctl-managed VPC/IAM
```

`teardown.sh` does **not** delete EFS or Aurora (they live outside eksctl).
Delete them separately:

```bash
# EFS: remove mount targets first, then the filesystem
FS_ID=$(aws efs describe-file-systems --region eu-west-2 \
  --query "FileSystems[?Name=='temporal-eks-efs'].FileSystemId | [0]" --output text)
for mt in $(aws efs describe-mount-targets --file-system-id "$FS_ID" --region eu-west-2 \
  --query 'MountTargets[].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id "$mt" --region eu-west-2
done
aws efs delete-file-system --file-system-id "$FS_ID" --region eu-west-2

# Aurora
aws rds delete-db-instance --db-instance-identifier temporal-pg-1 --skip-final-snapshot --region eu-west-2
aws rds delete-db-cluster  --db-cluster-identifier temporal-pg --skip-final-snapshot --region eu-west-2
```
