#!/bin/bash
# EC2 user data (Amazon Linux 2023). Runs once at first boot, as root.
#  Task 1.2  install YOLOv5 + PyTorch, verify with sample images
#  Data      copy a small public COCO val2017 sample to s3://BUCKET/dataset/
#  Task 2    build the Lambda container image and push it to ECR
#  Redesign  run the same pipeline as an HTTP service on port 8080 (no Lambda)
# Placeholders __X__ are filled in by 01_infra.sh.
BUCKET=__BUCKET__; REGION=__REGION__; TABLE=__TABLE__; ECR_URI=__ECR_URI__; TAG=__TAG__
export AWS_DEFAULT_REGION=$REGION
LOG=/var/log/yolo-setup.log
exec > >(tee -a $LOG) 2>&1
set -euxo pipefail

# Push the log to S3 every 20 s so progress is visible without logging in.
( while true; do aws s3 cp $LOG s3://$BUCKET/status/setup.log --quiet || true; sleep 20; done ) &
trap 'echo "SETUP EXIT CODE $?"; aws s3 cp $LOG s3://$BUCKET/status/setup.log --quiet' EXIT

echo "STAGE 1 packages"
dnf install -y python3.11 python3.11-pip docker git unzip mesa-libGL
systemctl enable --now docker

mkdir -p /opt/mk0468 && cd /opt/mk0468
aws s3 cp s3://$BUCKET/deploy/bundle.zip . && unzip -o -q bundle.zip

echo "STAGE 2 YOLOv5 on EC2 (Task 1.2)"
git clone --depth 1 --branch v7.0 https://github.com/ultralytics/yolov5.git
python3.11 -m venv venv
venv/bin/pip install --no-cache-dir numpy==1.26.4 torch==2.1.2+cpu torchvision==0.16.2+cpu \
  --extra-index-url https://download.pytorch.org/whl/cpu
venv/bin/pip install --no-cache-dir -r code/lambda_detect/requirements.txt opencv-python==4.8.1.78 thop
curl -sSL -o yolov5/yolov5s.pt https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5s.pt
( cd yolov5 && ../venv/bin/python -c "import torch, platform; print('python', platform.python_version(), 'torch', torch.__version__)" \
  && ../venv/bin/python detect.py --weights yolov5s.pt --source data/images --save-txt --save-conf ) 2>&1 | tee verify_detect.txt
aws s3 cp verify_detect.txt s3://$BUCKET/ec2-verify/verify_detect.txt
aws s3 cp yolov5/runs/detect/exp s3://$BUCKET/ec2-verify/ --recursive

echo "STAGE 3 sample dataset (COCO val2017, CC BY 4.0)"
mkdir -p dataset
for id in 000000000139 000000000285 000000000632 000000000724 000000000776 \
          000000000785 000000000802 000000000872 000000000885 000000001000; do
  curl -sSf -o dataset/$id.jpg http://images.cocodataset.org/val2017/$id.jpg
done
cp yolov5/data/images/bus.jpg yolov5/data/images/zidane.jpg dataset/
aws s3 cp dataset s3://$BUCKET/dataset/ --recursive

echo "STAGE 4 build and push the Lambda container image"
aws ecr get-login-password | docker login --username AWS --password-stdin ${ECR_URI%%/*}
docker build -t $ECR_URI:$TAG code/lambda_detect
docker push $ECR_URI:$TAG
docker images $ECR_URI

echo "STAGE 5 no-Lambda service on :8080 (redesign experiment)"
cat > /etc/systemd/system/yolo-server.service <<EOF
[Unit]
Description=YOLOv5 detection HTTP service (no-Lambda redesign)
After=network-online.target
[Service]
WorkingDirectory=/opt/mk0468/code/ec2_server
Environment=BUCKET=$BUCKET TABLE=$TABLE AWS_DEFAULT_REGION=$REGION
Environment=MODEL_PATH=/opt/mk0468/yolov5/yolov5s.pt YOLO_DIR=/opt/mk0468/yolov5 YOLOv5_AUTOINSTALL=false
ExecStart=/opt/mk0468/venv/bin/python server.py --port 8080
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now yolo-server
sleep 20 && curl -s localhost:8080/health

echo "SETUP COMPLETE"
