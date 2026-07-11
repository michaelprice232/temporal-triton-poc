from datetime import timedelta
from temporalio import workflow

with workflow.unsafe.imports_passed_through():
    from activities import greet, triton_infer


@workflow.defn
class SayHelloWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        return await workflow.execute_activity(
            greet,
            name,
            schedule_to_close_timeout=timedelta(seconds=10),
        )


@workflow.defn
class InferenceWorkflow:
    @workflow.run
    async def run(self, model_name: str = "densenet_onnx") -> dict:
        # Retries are on by default; if the sidecar is briefly not-ready the
        # activity retries rather than failing the workflow.
        return await workflow.execute_activity(
            triton_infer,
            model_name,
            start_to_close_timeout=timedelta(seconds=30),
        )
