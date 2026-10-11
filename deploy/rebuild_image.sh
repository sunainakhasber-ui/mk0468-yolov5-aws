#!/bin/bash
# Rebuild the Lambda container image on the EC2 host (via SSM Run Command) after a code change,
# then point alias "live" at a new version.  Usage:  bash deploy/rebuild_image.sh v2
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
TAG=${1:?image tag, e.g. v2}
for f in detector.py pipeline.py app.py Dockerfile requirements.txt; do
  aws s3 cp "$DIR/../code/lambda_detect/$f" "s3://$BUCKET/deploy/lambda_detect/$f" --quiet
done
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$EC2_NAME" Name=instance-state-name,Values=running \
      --query 'Reservations[0].Instances[0].InstanceId' --output text)
CMD_ID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript --timeout-seconds 1800 \
  --parameters "commands=[\"set -e\",\"cd /opt/mk0468\",\"aws s3 cp s3://$BUCKET/deploy/lambda_detect/ code/lambda_detect/ --recursive --region $REGION\",\"aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ECR_URI%%/*}\",\"docker build -q -t $ECR_URI:$TAG code/lambda_detect\",\"docker push -q $ECR_URI:$TAG\",\"systemctl restart yolo-server\"]" \
  --query Command.CommandId --output text)
echo "SSM command $CMD_ID on $IID"
aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$IID" 2>/dev/null || true
until s=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" --query Status --output text) && [ "$s" != "InProgress" ] && [ "$s" != "Pending" ]; do sleep 10; done
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" --query '[Status,StandardOutputContent,StandardErrorContent]' --output text | tail -5
[ "$s" = "Success" ] && IMAGE_TAG=$TAG bash "$DIR/02_lambda_api.sh"
