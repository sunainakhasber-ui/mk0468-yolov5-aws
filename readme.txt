Name:            Sunaina
Student number:  STUDENT_NUMBER

Project: Image Object Identification System on AWS using YOLOv5, Lambda, API Gateway and Amazon S3

Short description
-----------------
A user uploads a photo through a small web page. The photo goes straight to a private Amazon S3
bucket through a pre-signed URL. API Gateway (REST API, protected by an API key and a usage plan)
then calls an AWS Lambda function packaged as a container image. The function runs the pretrained
YOLOv5s model (v7.0, 80 COCO classes) on the image, writes an annotated copy to S3 (detected/),
writes the full result as JSON to S3 (results/) and indexes it in Amazon DynamoDB. YOLOv5 was
installed and verified on an EC2 instance, which also built the container image and pushed it to
Amazon ECR. The project also measures memory tuning, cold starts and concurrency, and compares the
Lambda design with a no-Lambda version that runs the same code as an HTTP service on EC2.

Live URL:    https://yp392mot69.execute-api.ap-southeast-2.amazonaws.com/prod/
Repository:  https://github.com/monkeypox7/mk0468-yolov5-aws
Dataset:     COCO 2017 validation images, https://cocodataset.org/#download
Model:       https://github.com/ultralytics/yolov5/releases/tag/v7.0 (yolov5s.pt)
Region:      ap-southeast-2 (Sydney)

Folders
-------
code/     source code
          lambda_detect/  detection Lambda: app.py, pipeline.py, detector.py, Dockerfile, requirements.txt
          lambda_web/     web page + pre-signed upload URL Lambda: app.py, index.html
          ec2_server/     the same pipeline as an HTTP service without Lambda (redesign experiment)
          tests/          load_test.py, memory_sweep.sh, ec2_compare.sh, make_charts.py
deploy/   runnable deployment scripts (run in AWS CloudShell, in this order)
          config.sh, 01_infra.sh, ec2_user_data.sh, 02_lambda_api.sh, 03_scaling.sh,
          rebuild_image.sh, 99_teardown.sh
images/   every image used in the report (screenshots, diagrams, charts, annotated outputs)

How to deploy (short version; full steps are in Section 4 of the report)
------------------------------------------------------------------------
1. Zip the code and deploy folders into bundle.zip, upload it to AWS CloudShell, unzip it in ~/mk0468.
2. bash deploy/01_infra.sh        (S3, DynamoDB, ECR, IAM, EC2 builder; wait for "SETUP COMPLETE")
3. bash deploy/02_lambda_api.sh   (Lambda functions, API Gateway, API key, usage plan)
4. bash deploy/03_scaling.sh      (DynamoDB auto scaling)  and  bash deploy/03_scaling.sh warm-on
5. Open the printed live URL, paste the API key, choose an image, click "Upload and detect".
6. bash deploy/99_teardown.sh --all   removes everything.
