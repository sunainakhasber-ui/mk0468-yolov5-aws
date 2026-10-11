#!/bin/bash
# Removes every resource created by the deploy scripts. Run only after marking is complete.
#   bash deploy/99_teardown.sh            stop the EC2 host only (keeps the live API working)
#   bash deploy/99_teardown.sh --all      delete EVERYTHING, including all images and results in S3
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"

IDS=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$EC2_NAME" \
      Name=instance-state-name,Values=pending,running,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
if [ "${1:-}" != "--all" ]; then
  [ -n "$IDS" ] && aws ec2 stop-instances --instance-ids $IDS >/dev/null && echo "Stopped EC2 $IDS"
  exit 0
fi

read -r -p "Delete ALL $PROJECT resources and data? Type yes: " ok; [ "$ok" = "yes" ] || exit 1
bash "$DIR/03_scaling.sh" pc-off
[ -n "$IDS" ] && aws ec2 terminate-instances --instance-ids $IDS >/dev/null && aws ec2 wait instance-terminated --instance-ids $IDS
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text)
PLAN_ID=$(aws apigateway get-usage-plans --query "items[?name=='$USAGE_PLAN'].id | [0]" --output text)
KEY_ID=$(aws apigateway get-api-keys --name-query "$API_KEY_NAME" --query "items[0].id" --output text)
[ "$PLAN_ID" != "None" ] && aws apigateway update-usage-plan --usage-plan-id "$PLAN_ID" \
  --patch-operations op=remove,path=/apiStages,value="$API_ID:$STAGE" && aws apigateway delete-usage-plan --usage-plan-id "$PLAN_ID"
[ "$KEY_ID" != "None" ] && aws apigateway delete-api-key --api-key "$KEY_ID"
[ "$API_ID" != "None" ] && aws apigateway delete-rest-api --rest-api-id "$API_ID"
aws lambda delete-function --function-name "$DETECT_FN"
aws lambda delete-function --function-name "$WEB_FN"
for dim in Read Write; do
  aws application-autoscaling deregister-scalable-target --service-namespace dynamodb \
    --resource-id "table/$TABLE" --scalable-dimension "dynamodb:table:${dim}CapacityUnits"
done
aws dynamodb delete-table --table-name "$TABLE" >/dev/null
aws ecr delete-repository --repository-name "$ECR_REPO" --force >/dev/null
aws s3 rb "s3://$BUCKET" --force
aws iam remove-role-from-instance-profile --instance-profile-name "$EC2_PROFILE" --role-name "$EC2_ROLE"
aws iam delete-instance-profile --instance-profile-name "$EC2_PROFILE"
for role in "$EC2_ROLE" "$LAMBDA_ROLE"; do
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$p"; done
  aws iam delete-role-policy --role-name "$role" --policy-name "${PROJECT}-data-access"
  aws iam delete-role --role-name "$role"
done
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$EC2_SG" --query 'SecurityGroups[0].GroupId' --output text)
[ "$SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$SG_ID"
echo "Teardown complete"
