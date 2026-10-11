"""Load, concurrency and cold-start tests for the detection API (Tasks 3.2, 5.1, 5.2 and the reflection).

Run from AWS CloudShell (boto3 and credentials are already there). The API URL and API key are looked
up with boto3, so the key never has to be typed or pasted.

  python3 code/tests/load_test.py load --requests 60 --concurrency 10 --label burst-c10
  python3 code/tests/load_test.py probe --calls 5 --label probe          # sequential calls
  python3 code/tests/load_test.py insights --minutes 60                  # cold starts from CloudWatch REPORT lines
  python3 code/tests/load_test.py ec2 --requests 20 --concurrency 4      # same test against the EC2 service

Every run prints a summary and writes a CSV to s3://BUCKET/evidence/<label>.csv
"""
import argparse
import csv
import io
import json
import os
import statistics
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import boto3

REGION = os.environ.get("AWS_REGION", "ap-southeast-2")
PROJECT = "mk0468-yolo"
ACCOUNT = boto3.client("sts").get_caller_identity()["Account"]
BUCKET = f"{PROJECT}-{ACCOUNT}"
s3 = boto3.client("s3", region_name=REGION)


def api_target():
    apigw = boto3.client("apigateway", region_name=REGION)
    api_id = next(a["id"] for a in apigw.get_rest_apis()["items"] if a["name"] == f"{PROJECT}-api")
    key_id = apigw.get_api_keys(nameQuery=f"{PROJECT}-key")["items"][0]["id"]
    key = apigw.get_api_key(apiKey=key_id, includeValue=True)["value"]
    return f"https://{api_id}.execute-api.{REGION}.amazonaws.com/prod/detect", {"x-api-key": key}


def ec2_target():
    # Run this mode ON the EC2 host (via SSM): the security group has no inbound rules.
    return os.environ.get("EC2_URL", "http://localhost:8080/detect"), {}


def dataset_keys():
    objs = s3.list_objects_v2(Bucket=BUCKET, Prefix="dataset/").get("Contents", [])
    return [o["Key"] for o in objs if o["Key"].lower().endswith((".jpg", ".jpeg", ".png"))]


def call(url, headers, key, i):
    body = json.dumps({"key": key}).encode()
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    t0 = time.time()
    status, data = 0, {}
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, data = r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        status = e.code
        try:
            data = json.loads(e.read())
        except Exception:
            data = {}
    except Exception as e:  # timeouts, connection errors
        data = {"error": type(e).__name__}
    return {
        "i": i, "key": key, "status": status, "start": round(t0, 3),
        "latency_ms": round((time.time() - t0) * 1000, 1),
        "cold_start": data.get("cold_start"), "init_ms": data.get("init_ms"),
        "inference_ms": data.get("inference_ms"), "server_ms": data.get("total_ms"),
        "objects": data.get("object_count"), "error": data.get("error") or data.get("message"),
    }


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p / 100 * (len(values) - 1))))] if values else None


def report(rows, label, wall):
    ok = [r for r in rows if r["status"] == 200]
    lat = [r["latency_ms"] for r in ok]
    summary = {
        "label": label, "requests": len(rows), "ok": len(ok),
        "errors_by_status": {str(s): sum(1 for r in rows if r["status"] == s) for s in {r["status"] for r in rows} if s != 200},
        "cold_starts": sum(1 for r in ok if r["cold_start"]),
        "max_init_ms": max([r["init_ms"] or 0 for r in ok], default=0),
        "latency_ms": {"min": min(lat, default=None), "p50": pct(lat, 50), "p90": pct(lat, 90),
                       "p99": pct(lat, 99), "max": max(lat, default=None),
                       "mean": round(statistics.mean(lat), 1) if lat else None},
        "mean_inference_ms": round(statistics.mean([r["inference_ms"] for r in ok]), 1) if ok else None,
        "wall_s": round(wall, 1), "throughput_rps": round(len(ok) / wall, 2) if wall else None,
    }
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(sorted(rows, key=lambda r: r["start"]))
    s3.put_object(Bucket=BUCKET, Key=f"evidence/{label}.csv", Body=buf.getvalue().encode())
    s3.put_object(Bucket=BUCKET, Key=f"evidence/{label}.json", Body=json.dumps(summary, indent=2).encode())
    print(json.dumps(summary, indent=2))
    print(f"CSV: s3://{BUCKET}/evidence/{label}.csv")


def run_load(url, headers, n, conc, label):
    keys = dataset_keys()
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=conc) as pool:
        rows = list(pool.map(lambda i: call(url, headers, keys[i % len(keys)], i), range(n)))
    report(rows, label, time.time() - t0)


def run_probe(url, headers, calls, pause, label):
    keys, rows = dataset_keys(), []
    t0 = time.time()
    for i in range(calls):
        rows.append(call(url, headers, keys[i % len(keys)], i))
        r = rows[-1]
        print(f"call {i + 1}: HTTP {r['status']} {r['latency_ms']} ms cold_start={r['cold_start']} init_ms={r['init_ms']}")
        time.sleep(pause)
    report(rows, label, time.time() - t0)


def insights(minutes):
    logs = boto3.client("logs", region_name=REGION)
    q = ('filter @type = "REPORT" | stats count(*) as invocations, count(@initDuration) as cold_starts, '
         'round(avg(@initDuration),0) as avg_init_ms, round(max(@initDuration),0) as max_init_ms, '
         'round(avg(@duration),0) as avg_duration_ms, round(max(@maxMemoryUsed)/1000000,0) as max_mem_mb, '
         'max(@memorySize)/1000000 as memory_mb')
    qid = logs.start_query(logGroupName=f"/aws/lambda/{PROJECT}-detect", queryString=q,
                           startTime=int(time.time() - minutes * 60), endTime=int(time.time()))["queryId"]
    while True:
        res = logs.get_query_results(queryId=qid)
        if res["status"] in ("Complete", "Failed", "Cancelled"):
            break
        time.sleep(1)
    print(f"Logs Insights, last {minutes} min, /aws/lambda/{PROJECT}-detect:")
    for row in res["results"]:
        print(json.dumps({c["field"]: c["value"] for c in row}, indent=2))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["load", "probe", "insights", "ec2"])
    ap.add_argument("--requests", type=int, default=30)
    ap.add_argument("--concurrency", type=int, default=5)
    ap.add_argument("--calls", type=int, default=5)
    ap.add_argument("--pause", type=float, default=1.0)
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--label", default=None)
    a = ap.parse_args()
    if a.mode == "insights":
        insights(a.minutes)
    elif a.mode == "probe":
        run_probe(*api_target(), a.calls, a.pause, a.label or "probe")
    elif a.mode == "ec2":
        run_load(*ec2_target(), a.requests, a.concurrency, a.label or f"ec2-c{a.concurrency}")
    else:
        run_load(*api_target(), a.requests, a.concurrency, a.label or f"load-c{a.concurrency}")
