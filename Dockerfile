FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
# psycopg2-binary required for ingest_rag_to_landing.py (Postgres); ensure it is installed
RUN pip install --no-cache-dir -r requirements.txt uvicorn psycopg2-binary

COPY app ./app/
COPY scripts ./scripts/
COPY models ./models/
COPY analyses ./analyses/
COPY macros ./macros/
COPY tests ./tests/
COPY dbt_project.yml profiles.yml ./

ENV PORT=8080
ENV PYTHONPATH=/app
EXPOSE 8080

# Ensure data dir exists for SQLite job store
RUN mkdir -p /app/data

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
