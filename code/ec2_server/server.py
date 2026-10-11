"""No-Lambda redesign: the same detection pipeline served as a long-running HTTP service on EC2.

Reuses detector.py and pipeline.py from ../lambda_detect unchanged. The model is loaded once at
start-up, so there is no per-request cold start; the trade-off is a server that is billed 24/7
and must be scaled with an Auto Scaling group instead of by Lambda.

Run:  BUCKET=... TABLE=... python server.py --port 8080
API:  POST /detect  {"key": "dataset/x.jpg"}     GET /health
"""
import argparse
import json
import logging
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lambda_detect"))
from detector import Detector  # noqa: E402
import pipeline  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
START = time.perf_counter()
DETECTOR = Detector(os.environ.get("MODEL_PATH", "yolov5s.pt"), os.environ.get("YOLO_DIR", "yolov5"))
LOAD_MS = round((time.perf_counter() - START) * 1000, 1)
# Design note: one model behind a global lock = one inference at a time per instance;
# scale out with more instances behind a load balancer rather than threads.
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"status": "ok", "model_load_ms": LOAD_MS})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/detect":
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
            with LOCK:
                record = pipeline.process(DETECTOR, payload.get("bucket"), payload.get("key"),
                                          extra={"cold_start": False, "init_ms": 0, "runtime": "ec2"})
            self._send(200, record)
        except (pipeline.BadRequest, pipeline.NotFound) as exc:
            self._send(exc.status, {"error": str(exc)})
        except json.JSONDecodeError:
            self._send(400, {"error": "request body must be JSON"})
        except Exception:
            logging.exception("unhandled error")
            self._send(500, {"error": "internal error"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    logging.info("model loaded in %s ms, listening on :%s", LOAD_MS, args.port)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
