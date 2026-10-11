#!/bin/bash
# Shared names for every deploy script. Run the scripts from AWS CloudShell (or any shell with AWS CLI v2).
export REGION="${REGION:-ap-southeast-2}"
export AWS_DEFAULT_REGION="$REGION"
export ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export PROJECT="mk0468-yolo"

export BUCKET="${PROJECT}-${ACCOUNT_ID}"                 # images, annotated images, JSON results
export TABLE="${PROJECT}-detections"                     # DynamoDB index of detections
export ECR_REPO="${PROJECT}-detect"                      # Lambda container image
export ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
export IMAGE_TAG="${IMAGE_TAG:-v2}"   # v1 = first build, v2 = warm-up handler

export DETECT_FN="${PROJECT}-detect"                     # YOLOv5 Lambda (container image)
export WEB_FN="${PROJECT}-web"                           # UI + pre-signed upload URL Lambda (zip)
export LAMBDA_ROLE="${PROJECT}-lambda-role"
export EC2_ROLE="${PROJECT}-ec2-role"
export EC2_PROFILE="${PROJECT}-ec2-profile"
export EC2_SG="${PROJECT}-sg"
export EC2_NAME="${PROJECT}-builder"
export EC2_TYPE="${EC2_TYPE:-m7i-flex.large}"

export API_NAME="${PROJECT}-api"
export STAGE="prod"
export USAGE_PLAN="${PROJECT}-plan"
export API_KEY_NAME="${PROJECT}-key"
