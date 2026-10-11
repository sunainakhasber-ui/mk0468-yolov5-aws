#!/bin/bash
# Step 1 - storage, database, container registry, IAM roles and the EC2 build/inference host.
# Idempotent: safe to re-run. Usage (CloudShell, from the project root):  bash deploy/01_infra.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
echo "Account $ACCOUNT_ID  Region $REGION  Bucket $BUCKET"

# ---------- S3 bucket (private, encrypted, CORS for browser uploads via pre-signed URLs) ----------
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint="$REGION"
fi
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{"CORSRules":[{
  "AllowedOrigins":["https://*.execute-api.'"$REGION"'.amazonaws.com"],
  "AllowedMethods":["PUT","GET"],"AllowedHeaders":["*"],"MaxAgeSeconds":3000}]}'
# Uploaded originals are temporary; results are kept.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-uploads","Status":"Enabled","Filter":{"Prefix":"uploads/"},"Expiration":{"Days":30}}]}'

# ---------- DynamoDB (provisioned + auto scaling is configured in 03_scaling.sh) ----------
if ! aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws dynamodb create-table --table-name "$TABLE" \
    --attribute-definitions AttributeName=image_key,AttributeType=S \
    --key-schema AttributeName=image_key,KeyType=HASH \
    --billing-mode PROVISIONED --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5
  aws dynamodb wait table-exists --table-name "$TABLE"
fi

# ---------- ECR repository for the Lambda container image ----------
aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ECR_REPO" --image-scanning-configuration scanOnPush=true >/dev/null

# ---------- IAM: Lambda execution role (least privilege for this bucket and table) ----------
if ! aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name "${PROJECT}-data-access" --policy-document '{
  "Version":"2012-10-17",
  "Statement":[
    {"Sid":"ReadWriteImagesAndResults","Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],
     "Resource":"arn:aws:s3:::'"$BUCKET"'/*"},
    {"Sid":"ListSoMissingKeysReturn404","Effect":"Allow","Action":["s3:ListBucket"],
     "Resource":"arn:aws:s3:::'"$BUCKET"'"},
    {"Sid":"WriteDetections","Effect":"Allow","Action":["dynamodb:PutItem"],
     "Resource":"arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/'"$TABLE"'"}
  ]}'

# ---------- IAM: EC2 role (build + push image, read/write project bucket, SSM shell access) ----------
if ! aws iam get-role --role-name "$EC2_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$EC2_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$EC2_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam attach-role-policy --role-name "$EC2_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
fi
aws iam put-role-policy --role-name "$EC2_ROLE" --policy-name "${PROJECT}-data-access" --policy-document '{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:ListBucket"],
     "Resource":["arn:aws:s3:::'"$BUCKET"'","arn:aws:s3:::'"$BUCKET"'/*"]},
    {"Effect":"Allow","Action":["dynamodb:PutItem"],
     "Resource":"arn:aws:dynamodb:'"$REGION"':'"$ACCOUNT_ID"':table/'"$TABLE"'"}
  ]}'
if ! aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$EC2_PROFILE" --role-name "$EC2_ROLE"
  sleep 15   # instance profiles take a few seconds to become usable
fi

# ---------- Upload code bundle and launch the EC2 host ----------
aws s3 cp "$DIR/../bundle.zip" "s3://$BUCKET/deploy/bundle.zip"

if [ -z "$(aws ec2 describe-instances --filters Name=tag:Name,Values="$EC2_NAME" \
      Name=instance-state-name,Values=pending,running,stopped --query 'Reservations[].Instances[].InstanceId' --output text)" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$EC2_SG" Name=vpc-id,Values="$VPC_ID" \
          --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$SG_ID" = "None" ]; then
    # No inbound rules: shell access is through SSM Session Manager, not SSH.
    SG_ID=$(aws ec2 create-security-group --group-name "$EC2_SG" --vpc-id "$VPC_ID" \
            --description "YOLOv5 build and inference host" --query GroupId --output text)
  fi
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
        --query Parameter.Value --output text)
  sed -e "s|__BUCKET__|$BUCKET|; s|__REGION__|$REGION|; s|__TABLE__|$TABLE|; s|__ECR_URI__|$ECR_URI|; s|__TAG__|$IMAGE_TAG|" \
      "$DIR/ec2_user_data.sh" > /tmp/user_data.sh
  aws ec2 run-instances --image-id "$AMI" --instance-type "$EC2_TYPE" \
    --iam-instance-profile Name="$EC2_PROFILE" --security-group-ids "$SG_ID" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --metadata-options HttpTokens=required \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$EC2_NAME},{Key=Project,Value=$PROJECT}]" \
    --user-data file:///tmp/user_data.sh --query 'Instances[0].InstanceId' --output text
fi
echo "Done. Follow EC2 progress with:  aws s3 cp s3://$BUCKET/status/setup.log - | tail"
