#!/bin/bash
# No-Lambda redesign experiment: run the same load test ON the EC2 host against server.py (port 8080),
# via SSM Run Command (no SSH, no open inbound ports).  Usage (CloudShell):  bash code/tests/ec2_compare.sh
set -euo pipefail
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=mk0468-yolo-builder Name=instance-state-name,Values=running \
      --query 'Reservations[0].Instances[0].InstanceId' --output text)
RUN="cd /opt/mk0468 && export AWS_REGION=ap-southeast-2 && for c in 1 4 10; do venv/bin/python code/tests/load_test.py ec2 --requests \$((c*10)) --concurrency \$c --label ec2-c\$c | tr -d '\\n' ; echo; done"
CID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript --timeout-seconds 900 \
      --parameters "commands=[\"$RUN\"]" --query Command.CommandId --output text)
while s=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query Status --output text 2>/dev/null); [ "$s" = InProgress ] || [ "$s" = Pending ] || [ -z "$s" ]; do sleep 5; done
echo "SSM status: $s"
aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query StandardOutputContent --output text
