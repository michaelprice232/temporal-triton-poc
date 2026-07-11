# temporal-triton-poc

A self-hosted **Temporal + NVIDIA Triton** proof-of-concept on **Amazon EKS**, built
from the ground up. It demonstrates the architecture used for GPU-backed ML
inference orchestration: a **Temporal worker as the "main car" and a Triton
Inference Server as its "side car"**, co-located in one pod, with the worker
calling Triton over `localhost`.

This POC runs everything on **CPU** with small models (the pattern is identical
on GPU — you just request a GPU on the sidecar and schedule onto a GPU node).

---

## What it proves

A Temporal workflow, triggered from a laptop, is executed by a worker running in
EKS. One of its activities performs an image classification by calling a Triton
sidecar in the same pod, which serves an ONNX model off shared EFS storage. The
result comes back as a human-readable label ("COFFEE MUG").

```
   laptop                         EKS (temporal-eks, eu-west-2)
 ┌────────┐   StartWorkflow    ┌──────────────────────────────────────────────┐
 │ client │ ───(port-fwd)────► │  Temporal control plane (ns: temporal)         │
 │  .py   │    :7233           │  frontend / history / matching / worker        │
 └────────┘                    │        │ persistence + visibility (SQL)        │
                               │        ▼                                       │
                               │   Aurora PostgreSQL (Serverless v2)            │
                               │                                                │
                               │  Worker pod (ns: temporal-workers)             │
                               │  ┌───────────────────────────────────────┐    │
                               │  │ main:  temporal worker  ──localhost──┐ │    │
                               │  │ side:  triton server  ◄──:8000───────┘ │    │
                               │  │            │ reads model repo          │    │
                               │  └────────────┼──────────────────────────┘    │
                               │               ▼  EFS (efs-sc, ReadWriteMany)   │
                               └──────────────────────────────────────────────┘
```

## Tech

| Layer            | Choice                                                        |
|------------------|---------------------------------------------------------------|
| Cluster          | EKS **Auto Mode** (eu-west-2), provisioned with `eksctl`       |
| Persistence      | **Aurora PostgreSQL Serverless v2** (default + visibility DBs) |
| Shared storage   | **EFS**, dynamic provisioning via `efs-sc` (access points)     |
| Orchestrator     | **Temporal** OSS control plane (Helm chart 1.5.0 / server 1.31)|
| Model serving    | **NVIDIA Triton** 26.06 (ONNX backend, CPU)                    |
| Worker           | Python SDK (`temporalio` 1.30), packaged to ECR               |
| Sidecar wiring   | Native k8s sidecar (initContainer + `restartPolicy: Always`)  |

---

## Runbook (run in order)

Each directory is a self-contained step with its own README. Follow them top to
bottom.

1. **[`01-infra-eks-aurora-efs/`](./01-infra-eks-aurora-efs/)** — Provision the
   EKS Auto Mode cluster, the Aurora PostgreSQL Serverless v2 cluster (+ the two
   databases), and EFS with the dynamic `efs-sc` StorageClass.

2. **[`02-temporal-control-plane/`](./02-temporal-control-plane/)** — Install the
   Temporal control plane via Helm, pointed at Aurora over TLS.

3. **[`03-temporal-workers/`](./03-temporal-workers/)** — Build the worker image,
   convert a model onto EFS, and deploy the worker **with the Triton sidecar**.

4. **[`04-sample-client/`](./04-sample-client/)** — Trigger the inference workflow
   from your laptop and get the classification back.

## Prerequisites

- `awscli` v2 (credentials that can create EKS/VPC/IAM/RDS/EFS)
- `eksctl` >= 0.210, `kubectl`, `helm` (3.x or 4.x), `jq`, `docker`
- Python 3.10+ and the `temporal` CLI (for the client step)
- Region used throughout: **eu-west-2 (London)** — change in the scripts if needed

## Placeholders to fill in

A few values are intentionally left as `REPLACE_...` so no account-specific data
is committed:

| Placeholder                      | Where                                   | What |
|----------------------------------|-----------------------------------------|------|
| `REPLACE_AURORA_WRITER_ENDPOINT` | `02-.../values.aurora-postgres.yaml`    | Aurora **writer** endpoint |
| `REPLACE_ECR_IMAGE`              | `03-.../k8s/deployment*.yaml`           | Your pushed worker image ref |
| `TEMPORAL_DB_PASSWORD` (env)     | `02-.../install-temporal.sh`            | Aurora DB password (never committed) |

## Cost & teardown

This spins up real billable resources (EKS, NAT gateway, Aurora, EFS). Tear
everything down when done — see the teardown notes in step 1's README (the EFS
filesystem and Aurora cluster are **not** deleted by the cluster teardown and
must be removed separately).

> Built as a portfolio POC. Not production-hardened — see each README's "Going to
> production" notes for what would change (HA NAT, TLS host verification, secrets
> management, GPU nodes, autoscaling on task-queue depth).
