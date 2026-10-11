#!/bin/bash
# Step 2 - Lambda functions + API Gateway (REST) with API key and usage plan.
# Needs the container image pushed by the EC2 host (01_infra.sh). Idempotent.
# Usage (CloudShell, from the project root):  bash deploy/02_lambda_api.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE" --query Role.Arn --output text)
ENV="Variables={BUCKET=$BUCKET,TABLE=$TABLE}"

# ---------- Detect function: container image, 3008 MB, 60 s ----------
if aws lambda get-function --function-name "$DETECT_FN" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$DETECT_FN" --image-uri "$ECR_URI:$IMAGE_TAG" >/dev/null
else
  aws lambda create-function --function-name "$DETECT_FN" --package-type Image \
    --code ImageUri="$ECR_URI:$IMAGE_TAG" --role "$ROLE_ARN" --architectures x86_64 \
    --memory-size 3008 --timeout 60 --ephemeral-storage Size=512 --environment "$ENV" \
    --description "YOLOv5s object detection on images in S3" >/dev/null
fi
aws lambda wait function-updated-v2 --function-name "$DETECT_FN"
# Publish an immutable version behind alias "live": API Gateway calls the alias, so provisioned
# concurrency and its auto scaling (03_scaling.sh) can be attached to it.
VERSION=$(aws lambda publish-version --function-name "$DETECT_FN" --query Version --output text)
aws lambda update-alias --function-name "$DETECT_FN" --name live --function-version "$VERSION" >/dev/null 2>&1 || \
  aws lambda create-alias --function-name "$DETECT_FN" --name live --function-version "$VERSION" >/dev/null
echo "detect function version $VERSION -> alias live"

# ---------- Web function: zip (UI + pre-signed upload URL), 256 MB ----------
rm -f /tmp/web.zip && (cd "$DIR/../code/lambda_web" && zip -q /tmp/web.zip app.py index.html)
if aws lambda get-function --function-name "$WEB_FN" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$WEB_FN" --zip-file fileb:///tmp/web.zip >/dev/null
else
  aws lambda create-function --function-name "$WEB_FN" --runtime python3.12 --handler app.handler \
    --zip-file fileb:///tmp/web.zip --role "$ROLE_ARN" --memory-size 256 --timeout 10 \
    --environment "Variables={BUCKET=$BUCKET}" --description "Web UI and pre-signed S3 upload URLs" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "$WEB_FN"

# ---------- REST API ----------
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text)
if [ "$API_ID" = "None" ]; then
  API_ID=$(aws apigateway create-rest-api --name "$API_NAME" --endpoint-configuration types=REGIONAL \
           --description "YOLOv5 object detection API" --query id --output text)
fi
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/'].id | [0]" --output text)

resource_id() {  # get or create /<part>
  local id; id=$(aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/$1'].id | [0]" --output text)
  [ "$id" = "None" ] && id=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" \
                             --path-part "$1" --query id --output text)
  echo "$id"
}

wire() {  # wire <resource-id> <METHOD> <function> <api-key-required true|false> [alias]
  local rid=$1 method=$2 fn=$3 key=$4 alias=${5:-}
  local fn_arn; fn_arn=$(aws lambda get-function --function-name "$fn" --query Configuration.FunctionArn --output text)
  local qual=(); if [ -n "$alias" ]; then fn_arn="$fn_arn:$alias"; qual=(--qualifier "$alias"); fi
  if aws apigateway get-method --rest-api-id "$API_ID" --resource-id "$rid" --http-method "$method" >/dev/null 2>&1; then
    aws apigateway update-method --rest-api-id "$API_ID" --resource-id "$rid" --http-method "$method" \
      --patch-operations op=replace,path=/apiKeyRequired,value="$key" >/dev/null
  else
    local flag=--no-api-key-required; [ "$key" = true ] && flag=--api-key-required
    aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$rid" --http-method "$method" \
      --authorization-type NONE "$flag" >/dev/null
  fi
  aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$rid" --http-method "$method" \
    --type AWS_PROXY --integration-http-method POST --timeout-in-millis 29000 \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$fn_arn/invocations" >/dev/null
  aws lambda add-permission --function-name "$fn" "${qual[@]}" --statement-id "apigw-$API_ID-$method-${rid}" \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/$method/*" >/dev/null 2>&1 || true
}

wire "$ROOT_ID" GET "$WEB_FN" false                           # public: the web page itself
wire "$(resource_id upload-url)" POST "$WEB_FN" true          # API key required
wire "$(resource_id detect)" POST "$DETECT_FN" true live      # API key required, alias "live"
aws lambda add-permission --function-name "$WEB_FN" --statement-id "apigw-$API_ID-root" \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/GET/" >/dev/null 2>&1 || true

aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE" \
  --description "deploy $(date -u +%FT%TZ)" >/dev/null
# Stage-level throttling and execution logs off by default (logging needs an account-level CloudWatch role).
aws apigateway update-stage --rest-api-id "$API_ID" --stage-name "$STAGE" --patch-operations \
  op=replace,path=/*/*/throttling/rateLimit,value=20 op=replace,path=/*/*/throttling/burstLimit,value=40 >/dev/null

# ---------- API key + usage plan (throttle + daily quota) ----------
PLAN_ID=$(aws apigateway get-usage-plans --query "items[?name=='$USAGE_PLAN'].id | [0]" --output text)
if [ "$PLAN_ID" = "None" ]; then
  PLAN_ID=$(aws apigateway create-usage-plan --name "$USAGE_PLAN" \
    --throttle rateLimit=10,burstLimit=20 --quota limit=2000,period=DAY \
    --api-stages apiId="$API_ID",stage="$STAGE" --query id --output text)
fi
KEY_ID=$(aws apigateway get-api-keys --name-query "$API_KEY_NAME" --query "items[0].id" --output text)
if [ "$KEY_ID" = "None" ]; then
  KEY_ID=$(aws apigateway create-api-key --name "$API_KEY_NAME" --enabled --query id --output text)
  aws apigateway create-usage-plan-key --usage-plan-id "$PLAN_ID" --key-id "$KEY_ID" --key-type API_KEY >/dev/null
fi

URL="https://$API_ID.execute-api.$REGION.amazonaws.com/$STAGE"
echo "API_ID=$API_ID"
echo "Live URL:  $URL/"
echo "API key:   aws apigateway get-api-key --api-key $KEY_ID --include-value --query value --output text"
