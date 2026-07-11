"""Temporal worker — self-hosted control plane, in-cluster frontend.

Config comes from env (ConfigMap/Secret in k8s). Defaults target the
self-hosted frontend deployed by the Helm chart in the `temporal` namespace.

Auth is wired but optional: for the plaintext POC there is no TLS/API key.
If TEMPORAL_API_KEY is set later (e.g. moving to Temporal Cloud), the worker
automatically connects over TLS with it — no code change needed.
"""
import asyncio
import logging
import os
import signal

from temporalio.client import Client
from temporalio.worker import Worker
from temporalio import workflow

with workflow.unsafe.imports_passed_through():
    from workflows import SayHelloWorkflow, InferenceWorkflow
    from activities import greet, triton_infer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("worker")


def _bool(name: str, default: str = "false") -> bool:
    return os.environ.get(name, default).strip().lower() in ("1", "true", "yes")


async def connect() -> Client:
    address = os.environ.get(
        "TEMPORAL_ADDRESS", "temporal-frontend.temporal.svc.cluster.local:7233"
    )
    namespace = os.environ.get("TEMPORAL_NAMESPACE", "default")

    api_key = os.environ.get("TEMPORAL_API_KEY") or None
    tls = _bool("TEMPORAL_TLS") or bool(api_key)  # API key implies TLS

    log.info(
        "Connecting to Temporal address=%s namespace=%s tls=%s api_key=%s",
        address, namespace, tls, "set" if api_key else "none",
    )
    return await Client.connect(address, namespace=namespace, tls=tls, api_key=api_key)


async def main() -> None:
    task_queue = os.environ.get("TEMPORAL_TASK_QUEUE", "my-task-queue")
    client = await connect()

    worker = Worker(
        client,
        task_queue=task_queue,
        workflows=[SayHelloWorkflow, InferenceWorkflow],
        activities=[greet, triton_infer],
    )

    # Graceful shutdown: k8s sends SIGTERM on pod stop; ctrl-c sends SIGINT.
    interrupt = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, interrupt.set)

    log.info("Worker started on task queue '%s' — polling for tasks", task_queue)
    async with worker:
        await interrupt.wait()
    log.info("Shutdown signal received — worker stopped cleanly")


if __name__ == "__main__":
    asyncio.run(main())
