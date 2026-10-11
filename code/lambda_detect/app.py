"""AWS Lambda handler: object detection on an image stored in S3.

Accepted events:
  * API Gateway (REST, Lambda proxy):  POST /detect  body {"key": "uploads/x.jpg", "bucket": "..."}
  * Direct invoke / console test:      {"key": "dataset/x.jpg"}
"""
import json
import logging
import os
import time

logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger("handler")

_init_start = time.perf_counter()
from detector import Detector  # noqa: E402  (imported after the timer on purpose)
import pipeline  # noqa: E402

# Loaded once per execution environment and reused by every warm invocation.
DETECTOR = Detector(os.environ.get("MODEL_PATH", "/opt/ml/yolov5s.pt"),
                    os.environ.get("YOLO_DIR", "/opt/yolov5"))
INIT_MS = round((time.perf_counter() - _init_start) * 1000, 1)
_cold = True


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    global _cold
    cold, _cold = _cold, False
    request_id = getattr(context, "aws_request_id", None)
    is_api = isinstance(event, dict) and "httpMethod" in event

    # Scheduled keep-warm ping from EventBridge (03_scaling.sh warm-on): no S3/DynamoDB work.
    if isinstance(event, dict) and event.get("warmup"):
        log.info(json.dumps({"event": "warmup", "cold_start": cold, "init_ms": INIT_MS if cold else 0}))
        return {"warm": True, "cold_start": cold, "init_ms": INIT_MS if cold else 0}

    try:
        if is_api:
            try:
                payload = json.loads(event.get("body") or "{}")
            except json.JSONDecodeError:
                raise pipeline.BadRequest("request body must be JSON")
        else:
            payload = event or {}
        if not isinstance(payload, dict):
            raise pipeline.BadRequest("request body must be a JSON object")

        record = pipeline.process(
            DETECTOR, payload.get("bucket"), payload.get("key"), request_id,
            extra={
                "cold_start": cold,
                "init_ms": INIT_MS if cold else 0,
                "memory_mb": int(getattr(context, "memory_limit_in_mb", 0) or 0),
                "runtime": "lambda",
            })
        log.info(json.dumps({"event": "invocation", "request_id": request_id,
                             "cold_start": cold, "init_ms": INIT_MS if cold else 0}))
        return _response(200, record) if is_api else record

    except (pipeline.BadRequest, pipeline.NotFound) as exc:
        log.warning(json.dumps({"event": "client_error", "request_id": request_id, "error": str(exc)}))
        if not is_api:
            raise
        return _response(exc.status, {"error": str(exc), "request_id": request_id})
    except Exception:
        log.exception("unhandled error")
        if not is_api:
            raise
        return _response(500, {"error": "internal error, see CloudWatch logs", "request_id": request_id})
