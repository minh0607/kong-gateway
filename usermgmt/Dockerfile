FROM python:3.12-alpine
RUN apk add --no-cache apache2-utils tzdata
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./
COPY static/ static/
ENV TZ=UTC
EXPOSE 5000
CMD ["gunicorn", "--workers", "1", "--threads", "4", \
     "--bind", "0.0.0.0:5000", "--access-logfile", "-", "app:app"]
