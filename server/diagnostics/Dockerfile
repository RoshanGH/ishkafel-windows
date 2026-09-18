FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd -u 10001 -m reports && mkdir /data && chown reports /data
COPY app.py database.py purge.py ./
USER reports
ENV REPORT_BIND=0.0.0.0 REPORT_DATA_DIR=/data
EXPOSE 8787
CMD ["python", "app.py"]
