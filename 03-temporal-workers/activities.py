import asyncio
import os

from temporalio import activity


@activity.defn
async def greet(name: str) -> str:
    return f"Hello {name}"


@activity.defn
async def triton_infer(model_name: str) -> dict:
    """Classify a real image against the co-located Triton sidecar over localhost.

    Feeds the mug image with the same preprocessing Triton's `image_client -s
    INCEPTION` uses, and asks Triton for classification output so it returns the
    human-readable labels from the model's label file (densenet_labels.txt) —
    i.e. "COFFEE MUG" rather than a bare class index.

    Heavy imports (numpy, tritonclient, pillow) are lazy so they never touch the
    workflow sandbox.
    """
    import numpy as np
    import tritonclient.http as httpclient
    from PIL import Image

    url = os.environ.get("TRITON_URL", "localhost:8000")
    image_path = os.environ.get("IMAGE_PATH", "/app/mug.jpg")
    topk = int(os.environ.get("TRITON_TOPK", "3"))

    def _infer() -> dict:
        client = httpclient.InferenceServerClient(url=url, verbose=False)
        if not client.is_server_ready():
            raise RuntimeError(f"Triton at {url} is not ready")
        if not client.is_model_ready(model_name):
            raise RuntimeError(f"model '{model_name}' is not ready on Triton")

        # Preprocess exactly like image_client -s INCEPTION:
        #   PIL RGB -> resize 224x224 -> (x/127.5 - 1) -> transpose HWC->CHW
        # densenet_onnx input "data_0" is FP32, FORMAT_NCHW, [3,224,224].
        img = Image.open(image_path).convert("RGB").resize((224, 224))
        arr = np.asarray(img, dtype=np.float32) / 127.5 - 1.0
        arr = np.transpose(arr, (2, 0, 1))

        inp = httpclient.InferInput("data_0", arr.shape, "FP32")
        inp.set_data_from_numpy(arr)
        # class_count => Triton maps indices to labels via the model's label file
        # and returns "score:index:label" strings, top-K sorted.
        out = httpclient.InferRequestedOutput("fc6_1", class_count=topk)

        res = client.infer(model_name=model_name, inputs=[inp], outputs=[out])

        top = []
        for entry in res.as_numpy("fc6_1"):
            score, index, label = entry.decode("utf-8").split(":", 2)
            top.append({"label": label, "index": int(index), "score": float(score)})
        return {"model": model_name, "image": os.path.basename(image_path), "top": top}

    activity.logger.info("Classifying %s on Triton %s model=%s", image_path, url, model_name)
    # tritonclient http is blocking — run it off the event loop.
    return await asyncio.to_thread(_infer)
