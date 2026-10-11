#!/bin/bash
# Step 3 - scaling policies.
#   bash deploy/03_scaling.sh            DynamoDB auto scaling + Lambda reserved concurrency
#   bash deploy/03_scaling.sh pc-on      + provisioned concurrency (1..3, target tracking 70 %) on alias "live"
#   bash deploy/03_scaling.sh pc-off     remove provisioned concurrency (it is billed per hour)
#   bash deploy/03_scaling.sh warm-on    EventBridge keep-warm ping every 5 minutes (warm-off removes it)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
MODE=${1:-base}

if [ "$MODE" = "base" ]; then
  # ---- DynamoDB: target tracking keeps consumed/provisioned capacity near 70 % (5..100 units) ----
  for dim in Read Write; do
    aws application-autoscaling register-scalable-target --service-namespace dynamodb \
      --resource-id "table/$TABLE" --scalable-dimension "dynamodb:table:${dim}CapacityUnits" \
      --min-capacity 5 --max-capacity 100
    aws application-autoscaling put-scaling-policy --service-namespace dynamodb \
      --resource-id "table/$TABLE" --scalable-dimension "dynamodb:table:${dim}CapacityUnits" \
      --policy-name "${TABLE}-${dim,,}-tt70" --policy-type TargetTrackingScaling \
      --target-tracking-scaling-policy-configuration \
      "{\"TargetValue\":70.0,\"PredefinedMetricSpecification\":{\"PredefinedMetricType\":\"DynamoDB${dim}CapacityUtilization\"},\"ScaleInCooldown\":60,\"ScaleOutCooldown\":60}" >/dev/null
  done
  echo "DynamoDB auto scaling: 5..100 RCU/WCU, target 70 %"

  # ---- Lambda: reserve concurrency so a traffic spike cannot starve other functions in the account ----
  LIMIT=$(aws lambda get-account-settings --query AccountLimit.ConcurrentExecutions --output text)
  echo "Account concurrency limit: $LIMIT"
  if [ "$LIMIT" -ge 120 ]; then   # Lambda must keep 100 unreserved after the reservation
    aws lambda put-function-concurrency --function-name "$DETECT_FN" --reserved-concurrent-executions 20 >/dev/null
    echo "Reserved concurrency for $DETECT_FN: 20"
  else
    echo "Account limit below 120: reserved concurrency skipped (Lambda keeps 100 unreserved; request a quota increase)."
  fi
fi

if [ "$MODE" = "pc-on" ]; then
  aws lambda put-provisioned-concurrency-config --function-name "$DETECT_FN" --qualifier live \
    --provisioned-concurrent-executions 1 >/dev/null
  aws application-autoscaling register-scalable-target --service-namespace lambda \
    --resource-id "function:$DETECT_FN:live" --scalable-dimension lambda:function:ProvisionedConcurrency \
    --min-capacity 1 --max-capacity 3
  aws application-autoscaling put-scaling-policy --service-namespace lambda \
    --resource-id "function:$DETECT_FN:live" --scalable-dimension lambda:function:ProvisionedConcurrency \
    --policy-name "${DETECT_FN}-pc-tt70" --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration \
    '{"TargetValue":0.7,"PredefinedMetricSpecification":{"PredefinedMetricType":"LambdaProvisionedConcurrencyUtilization"}}' >/dev/null
  echo "Waiting for provisioned concurrency to be READY..."
  until [ "$(aws lambda get-provisioned-concurrency-config --function-name "$DETECT_FN" --qualifier live --query Status --output text)" = "READY" ]; do sleep 15; done
  echo "Provisioned concurrency READY (1..3, target 70 %)"
fi

if [ "$MODE" = "warm-on" ]; then
  # Keep one execution environment warm: EventBridge pings alias "live" every 5 minutes.
  ALIAS_ARN=$(aws lambda get-alias --function-name "$DETECT_FN" --name live --query AliasArn --output text)
  RULE_ARN=$(aws events put-rule --name "${PROJECT}-warmup" --schedule-expression "rate(5 minutes)" \
    --description "Keep one YOLOv5 Lambda environment warm" --query RuleArn --output text)
  aws lambda add-permission --function-name "$DETECT_FN" --qualifier live --statement-id "${PROJECT}-warmup" \
    --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn "$RULE_ARN" >/dev/null 2>&1 || true
  aws events put-targets --rule "${PROJECT}-warmup" \
    --targets "Id=detect-live,Arn=$ALIAS_ARN,Input='{\"warmup\":true}'" >/dev/null
  echo "Warm-up rule enabled: rate(5 minutes) -> $ALIAS_ARN"
fi

if [ "$MODE" = "warm-off" ]; then
  aws events remove-targets --rule "${PROJECT}-warmup" --ids detect-live >/dev/null 2>&1 || true
  aws events delete-rule --name "${PROJECT}-warmup" 2>/dev/null || true
  echo "Warm-up rule removed"
fi

if [ "$MODE" = "pc-off" ]; then
  aws application-autoscaling deregister-scalable-target --service-namespace lambda \
    --resource-id "function:$DETECT_FN:live" --scalable-dimension lambda:function:ProvisionedConcurrency 2>/dev/null || true
  aws lambda delete-provisioned-concurrency-config --function-name "$DETECT_FN" --qualifier live 2>/dev/null || true
  echo "Provisioned concurrency removed"
fi
