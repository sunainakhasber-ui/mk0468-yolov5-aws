#!/bin/bash
# Task 5.1 - run the same probe at several Lambda memory sizes (CPU share grows with memory).
# Each size is published as a new version behind alias "live", so call 1 is always a cold start.
# Usage (CloudShell, project root):  bash code/tests/memory_sweep.sh 1024 2048 3008
set -euo pipefail
FN=mk0468-yolo-detect
for MEM in "$@"; do
  aws lambda update-function-configuration --function-name $FN --memory-size "$MEM" >/dev/null
  aws lambda wait function-updated-v2 --function-name $FN
  V=$(aws lambda publish-version --function-name $FN --description "memory $MEM" --query Version --output text)
  aws lambda update-alias --function-name $FN --name live --function-version "$V" >/dev/null
  echo "== memory $MEM MB (version $V)"
  python3 "$(dirname "$0")/load_test.py" probe --calls 8 --pause 1 --label "memory-$MEM" | grep -E "^call"
done
