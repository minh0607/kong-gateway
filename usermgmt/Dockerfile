FROM python:3.12-alpine
RUN apk add --no-cache apache2-utils && \
    pip install --no-cache-dir flask
WORKDIR /app
COPY app.py .
COPY static/ static/
EXPOSE 5000
CMD ["python", "app.py"]
