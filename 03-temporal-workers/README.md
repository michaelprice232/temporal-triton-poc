# Step 3 — Temporal workers (with the Triton sidecar)

Build the worker image, put a model on EFS, and deploy the worker **with a Triton
Inference Server sidecar** — the "intended final config": worker (main car) +
Triton (side car) in one pod, worker calling Triton over `localhost`.

Two deployments are included to show the progression:

| File | What | Use |
|------|------|-----|
| [`k8s/deployment.yaml`](./k8s/deployment.yaml) | plain worker, no Triton | validate the Temporal integration first |
| [`k8s/deployment-sidecar.yaml`](./k8s/deployment-sidecar.yaml) | worker **+ Triton sidecar** | the real thing |

Everything lives in the `temporal-workers` namespace.

---

## The worker code

- [`worker.py`](./worker.py) — env-driven worker. Defaults to the in-cluster
  frontend (`temporal-frontend.temporal.svc.cluster.local:7233`), `default`
  namespace, task queue `my-task-queue`. TLS/API-key are wired but optional (for
  a later move to Temporal Cloud). Graceful SIGTERM shutdown.
- [`workflows.py`](./workflows.py) — `SayHelloWorkflow` (smoke test) and
  `InferenceWorkflow` (calls Triton).
- [`activities.py`](./activities.py) — `greet`, and `triton_infer`: loads the
  baked-in `mug.jpg`, preprocesses it exactly like Triton's `image_client -s
  INCEPTION` (RGB → resize 224×224 → `x/127.5 − 1` → CHW), calls Triton at
  `localhost:8000`, and requests **classification output** so Triton returns the
  human labels from the model's `densenet_labels.txt`.
- [`Dockerfile`](./Dockerfile) — `python:3.12-slim`, installs deps, bakes in
  `mug.jpg`, runs as non-root.

### Build & push

```bash
ACCOUNT=<acct>; REGION=eu-west-2; REPO=temporal-worker; TAG=v1
aws ecr create-repository --repository-name $REPO --region $REGION 2>/dev/null || true
aws ecr get-login-password --region $REGION | docker login --username AWS \
  --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker build -t $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO:$TAG .
docker push $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO:$TAG
# put this image ref into k8s/deployment-sidecar.yaml (REPLACE_ECR_IMAGE)
```

---

## The model repository on EFS

The model repo is a **dynamic** EFS PVC (`triton-models`, `efs-sc`). A one-off
converter pod writes models into it; the Triton sidecar reads the same PVC.

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/efs-models.yaml       # dynamic PVC -> its own EFS access point
kubectl apply -f k8s/model-tools-pod.yaml  # ubuntu pod, same PVC mounted at /models
kubectl -n temporal-workers exec -it model-tools -- bash
```

Inside the converter pod (see [`k8s/model-tools-pod.yaml`](./k8s/model-tools-pod.yaml)):

```bash
apt update && apt install -y python3-venv python3-pip curl
# IMPORTANT: build the venv on LOCAL disk (/root), not on /models (EFS/NFS) —
# unpacking big wheels over NFS is painfully slow. Write only the final .onnx to EFS.
cd /root
python3 -m venv v && source v/bin/activate && pip install -U pip
pip install tf2onnx tensorflow-cpu onnx
# ... fetch a source model, then:
#   python -m tf2onnx.convert --input <model.pb> --inputs ... --outputs ... \
#     --output /models/<name>/1/model.onnx   (+ its config.pbtxt and labels)
```

> The converter pod has a nodeAffinity requiring a **≥ 3.5 GHz** instance
> (`eks.amazonaws.com/instance-cpu-sustained-clock-speed-mhz` > 3499) — the
> conversion is single-threaded, so clock speed matters more than core count.

When a valid `/models/<model>/1/model.onnx` (+ `config.pbtxt`, + label file)
exists, delete the converter pod:

```bash
kubectl -n temporal-workers delete pod model-tools
```

---

## Deploy the worker + Triton sidecar

```bash
# set REPLACE_ECR_IMAGE in k8s/deployment-sidecar.yaml first
kubectl apply -f k8s/deployment-sidecar.yaml
kubectl -n temporal-workers rollout status deploy/temporal-worker-triton

# watch the ordering: triton (init sidecar) becomes ready, THEN the worker starts
kubectl -n temporal-workers logs deploy/temporal-worker-triton -c triton -f
kubectl -n temporal-workers logs deploy/temporal-worker-triton -c worker -f
```

### How the sidecar is wired

Triton runs as a **native Kubernetes sidecar** — an `initContainer` with
`restartPolicy: Always` (GA since k8s 1.29). That gives two guarantees a plain
second container doesn't:

1. Triton **starts before** the worker's main container.
2. The worker starts only **after** Triton passes its `startupProbe`
   (`/v2/health/ready`), so the worker never polls for tasks before it can serve
   inference.

The worker reaches Triton at `localhost:8000` because containers in a pod share
the network namespace — no Service, no cross-namespace DNS. The model repo is
mounted **read-only** into the sidecar (Triton only reads it).

## Going to production (GPU)

The only change to reach the real GPU config: on the Triton sidecar, request a
GPU and schedule onto a GPU node —

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
# + tolerations/affinity for your GPU nodegroup
```

Everything else (localhost wiring, EFS model repo, native sidecar ordering) stays
the same. Scale the worker fleet on **task-queue depth** (e.g. KEDA's Temporal
scaler) so expensive GPU pods track backlog.
