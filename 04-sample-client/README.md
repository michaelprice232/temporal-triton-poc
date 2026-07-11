# Step 4 — Sample client call

Trigger the inference workflow from your laptop and get the image classification
back — the end-to-end proof.

The client is a plain Temporal **client**: it only asks the frontend to start a
workflow. The EKS worker executes it (calling its Triton sidecar) and returns the
result. Nothing model-related runs on your laptop.

## Prereq: reach the frontend

```bash
kubectl -n temporal port-forward svc/temporal-frontend 7233:7233
```

## Option A — the `temporal` CLI (no code)

```bash
temporal workflow execute \
  --type InferenceWorkflow --task-queue my-task-queue \
  --input '"densenet_onnx"' --address localhost:7233
```

Result:

```json
{"model":"densenet_onnx","image":"mug.jpg","top":[
  {"label":"COFFEE MUG","index":504,"score":15.34},
  {"label":"CUP","index":968,"score":13.22},
  {"label":"COFFEEPOT","index":505,"score":10.42}]}
```

## Option B — the Python client ([`run_inference.py`](./run_inference.py))

```bash
python -m venv .venv && source .venv/bin/activate
pip install temporalio
python run_inference.py
```

Output:

```
model: densenet_onnx   image: mug.jpg
top predictions:
    15.340  [504]  COFFEE MUG
    13.220  [968]  CUP
    10.420  [505]  COFFEEPOT
```

## What just happened

1. The client called the frontend (port-forwarded) → `StartWorkflow` on
   `my-task-queue`.
2. The EKS worker picked up the workflow task, then the activity task.
3. `triton_infer` preprocessed the mug image and called Triton at
   `localhost:8000` **inside the same pod**.
4. Triton ran the ONNX model (served off EFS) and returned classification labels.
5. The result flowed back through Temporal to the client.

You can watch the whole event history in the Temporal Web UI
(`kubectl -n temporal port-forward svc/temporal-web 8080:8080`) under the
`default` namespace — including the activity's completion and the JSON result.

That's the full loop: **laptop → Temporal (EKS) → worker → Triton sidecar → EFS
model → back**. The same shape scales to GPU-backed genAI inference by swapping
the model and giving the sidecar a GPU.
