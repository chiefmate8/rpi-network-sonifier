FROM python:3.12-slim
WORKDIR /app
COPY server.py ./
COPY static ./static
ENV PYTHONUNBUFFERED=1
EXPOSE 8080 5005/udp
CMD ["python", "server.py"]
