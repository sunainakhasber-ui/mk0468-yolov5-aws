"""Detection pipeline: read image from S3 -> YOLOv5 -> write results to S3 and DynamoDB.

Used by the Lambda handler (app.py) and by the EC2 server (ec2_server/server.py),
so both deployments behave identically and can be compared fairly.
"""
import json
import logging
import os
import posixpath
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

log = logging.getLogger("pipeline")

BUCKET = os.environ["BUCKET"]
TABLE = os.environ["TABLE"]
MAX_IMAGE_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", 15 * 1024 * 1024))
ALLOWED_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".webp")

# botocore "standard" retry mode retries throttling and 5xx errors with backoff.
_cfg = Config(retries={"max_attempts": 5, "mode": "standard"}, connect_timeout=5, read_timeout=20,
              signature_version="s3v4", s3={"addressing_style": "virtual"})
REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-2")
# Regional endpoint: pre-signed URLs for a new bucket then work without a 307 redirect.
s3 = boto3.client("s3", region_name=REGION, endpoint_url=f"https://s3.{REGION}.amazonaws.com", config=_cfg)
table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE)


class BadRequest(Exception):
    status = 400


class NotFound(Exception):
    status = 404


def with_retry(action, fn, attempts=3, base_delay=0.3):
    """Application-level retry on top of botocore's retries, with logging of every failure."""
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except (ClientError, BotoCoreError) as exc:
            log.warning(json.dumps({"event": "write_failed", "action": action,
                                    "attempt": attempt, "error": str(exc)}))
            if attempt == attempts:
                raise
            time.sleep(base_delay * 2 ** (attempt - 1))


def _to_decimal(value):
    return json.loads(json.dumps(value), parse_float=Decimal)


def validate(bucket, key):
    if not key or not isinstance(key, str):
        raise BadRequest("'key' (S3 object key of the image) is required")
    bucket = bucket or BUCKET
    if bucket != BUCKET:
        raise BadRequest(f"only images in bucket '{BUCKET}' can be processed")
    if not key.lower().endswith(ALLOWED_EXT):
        raise BadRequest(f"unsupported file type; allowed: {', '.join(ALLOWED_EXT)}")
    return bucket, key


def process(detector, bucket, key, request_id=None, extra=None):
    bucket, key = validate(bucket, key)
    request_id = request_id or str(uuid.uuid4())
    started = time.perf_counter()

    try:
        head = s3.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            raise NotFound(f"s3://{bucket}/{key} does not exist")
        raise
    if head["ContentLength"] > MAX_IMAGE_BYTES:
        raise BadRequest(f"image is larger than {MAX_IMAGE_BYTES // (1024 * 1024)} MB")

    image_bytes = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    objects, annotated, inference_ms, (width, height) = detector.detect(image_bytes)

    stem = posixpath.splitext(posixpath.basename(key))[0]
    annotated_key = f"detected/{stem}.jpg"
    result_key = f"results/{stem}.json"
    counts = {}
    for obj in objects:
        counts[obj["label"]] = counts.get(obj["label"], 0) + 1

    record = {
        "image_key": key,
        "bucket": bucket,
        "request_id": request_id,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "model": "yolov5s (v7.0, COCO-80)",
        "image_size": [width, height],
        "object_count": len(objects),
        "counts": counts,
        "objects": objects,
        "annotated_key": annotated_key,
        "result_key": result_key,
        "inference_ms": inference_ms,
        **(extra or {}),
    }

    # S3 is the primary store: if these writes fail after retries the request fails.
    with_retry("s3_put_annotated", lambda: s3.put_object(
        Bucket=bucket, Key=annotated_key, Body=annotated, ContentType="image/jpeg"))
    with_retry("s3_put_result", lambda: s3.put_object(
        Bucket=bucket, Key=result_key, Body=json.dumps(record, indent=2).encode(),
        ContentType="application/json"))

    # DynamoDB is the query index: a failure is logged and reported, not fatal.
    try:
        with_retry("dynamodb_put", lambda: table.put_item(Item=_to_decimal(record)))
        record["db_saved"] = True
    except (ClientError, BotoCoreError):
        log.exception("dynamodb write failed after retries")
        record["db_saved"] = False

    record["annotated_url"] = s3.generate_presigned_url(
        "get_object", Params={"Bucket": bucket, "Key": annotated_key}, ExpiresIn=3600)
    record["total_ms"] = round((time.perf_counter() - started) * 1000, 1)
    log.info(json.dumps({"event": "detected", "request_id": request_id, "key": key,
                         "objects": len(objects), "inference_ms": inference_ms,
                         "total_ms": record["total_ms"]}))
    return record
