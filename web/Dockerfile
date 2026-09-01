FROM python:3.12-slim

RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --break-system-packages -r requirements.txt

COPY app/ ./app/

# Non-root, matching the main container's approach. No PUID/PGID
# alignment needed here since this container never touches
# bind-mounted files for writing — only reads ./data/logs (:ro).
RUN useradd -m -u 1000 webuser
USER webuser

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
