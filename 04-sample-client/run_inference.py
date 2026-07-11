"""Laptop client: trigger the InferenceWorkflow and print the classification.

The client is a plain Temporal client — it does NOT run any workflow/activity
code. It just asks the frontend to start a workflow on the task queue; the EKS
worker executes it (calling its co-located Triton sidecar) and returns the result.

Prereq: port-forward the self-hosted frontend so localhost:7233 reaches it:
    kubectl -n temporal port-forward svc/temporal-frontend 7233:7233

Usage:
    python run_inference.py                 # classifies the baked-in mug image
    python run_inference.py densenet_onnx   # explicit model name
"""
import asyncio
import sys
import uuid

from temporalio.client import Client


async def main() -> None:
    model = sys.argv[1] if len(sys.argv) > 1 else "densenet_onnx"

    client = await Client.connect("localhost:7233", namespace="default")
    result = await client.execute_workflow(
        "InferenceWorkflow",
        model,
        id=f"inference-{uuid.uuid4()}",
        task_queue="my-task-queue",
    )

    print(f"\nmodel: {result['model']}   image: {result['image']}")
    print("top predictions:")
    for r in result["top"]:
        print(f"  {r['score']:8.3f}  [{r['index']:>3}]  {r['label']}")


if __name__ == "__main__":
    asyncio.run(main())
