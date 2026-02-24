FROM public.ecr.aws/docker/library/python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev libpq5 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --upgrade pip && pip install --no-cache-dir -r requirements.txt --ignore-installed
COPY main.py .
RUN useradd -m -u 1001 appuser && chown -R appuser /app
USER appuser
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8002
CMD ["python", "main.py"]
