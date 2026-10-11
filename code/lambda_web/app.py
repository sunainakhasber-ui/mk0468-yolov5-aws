"""Lightweight Lambda (zip, no ML libraries) behind API Gateway.

GET  /            -> the web user interface (index.html)
POST /upload-url  -> a pre-signed S3 PUT URL, so the browser uploads the image straight to S3.
                     This keeps image bytes out of API Gateway (10 MB payload limit) and out of
                     Lambda (6 MB synchronous payload limit).
"""
import json
import os
import re
import uuid

import boto3
from botocore.config import Config

BUCKET = os.environ["BUCKET"]
REGION = os.environ.get("AWS_REGION", "ap-southeast-2")
# Regional endpoint + SigV4: pre-signed URLs work for new buckets without a 307 redirect (which breaks CORS).
s3 = boto3.client("s3", region_name=REGION, endpoint_url=f"https://s3.{REGION}.amazonaws.com",
                  config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}))
TYPES = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp"}

with open(os.path.join(os.path.dirname(__file__), "index.html"), encoding="utf-8") as f:
    INDEX_HTML = f.read()


def _json(status, body):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps(body)}


def handler(event, context):
    method, path = event.get("httpMethod"), event.get("resource") or event.get("path")

    if method == "GET" and path == "/":
        return {"statusCode": 200, "headers": {"Content-Type": "text/html; charset=utf-8"}, "body": INDEX_HTML}

    if method == "POST" and path == "/upload-url":
        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return _json(400, {"error": "request body must be JSON"})
        name = str(body.get("filename", ""))
        ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
        if ext not in TYPES:
            return _json(400, {"error": "filename must end in .jpg, .jpeg, .png or .webp"})
        stem = re.sub(r"[^A-Za-z0-9_-]", "_", name.rsplit(".", 1)[0])[:40] or "image"
        key = f"uploads/{uuid.uuid4().hex[:8]}-{stem}.{ext}"
        url = s3.generate_presigned_url(
            "put_object", Params={"Bucket": BUCKET, "Key": key, "ContentType": TYPES[ext]}, ExpiresIn=300)
        return _json(200, {"bucket": BUCKET, "key": key, "upload_url": url, "content_type": TYPES[ext]})

    return _json(404, {"error": f"no route for {method} {path}"})
