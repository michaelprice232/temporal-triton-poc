FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker.py workflows.py activities.py ./
# Test image for the inference activity (same mug image_client uses).
COPY mug.jpg ./mug.jpg

# Run as an unprivileged user.
RUN useradd --create-home --uid 10001 appuser
USER appuser

CMD ["python", "worker.py"]
