# YOLOv5 object detection as an AWS Lambda container image (x86_64).
FROM public.ecr.aws/lambda/python:3.11

# CPU-only PyTorch keeps the image ~3x smaller than the CUDA build (Lambda has no GPU).
# "+cpu" pins the CPU wheels. numpy and Pillow are pinned to versions with manylinux2014 wheels
# (the Lambda python3.11 base is Amazon Linux 2, glibc 2.26), so nothing is compiled from source.
RUN pip install --no-cache-dir --only-binary=:all: numpy==1.26.4 Pillow==10.1.0 torch==2.1.2+cpu torchvision==0.16.2+cpu \
        --extra-index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt /tmp/requirements.txt
# --only-binary: transitive deps resolve to versions that ship wheels for this old glibc.
RUN pip install --no-cache-dir --only-binary=:all: -r /tmp/requirements.txt

# YOLOv5 v7.0 source and pretrained COCO weights are baked in, so nothing is downloaded at run time.
RUN python -c "import io,tarfile,urllib.request; \
tarfile.open(fileobj=io.BytesIO(urllib.request.urlopen('https://github.com/ultralytics/yolov5/archive/refs/tags/v7.0.tar.gz').read())).extractall('/opt')" \
    && mv /opt/yolov5-7.0 /opt/yolov5 \
    && mkdir -p /opt/ml \
    && python -c "import urllib.request; urllib.request.urlretrieve('https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5s.pt', '/opt/ml/yolov5s.pt')"

# Lambda's file system is read-only except /tmp.
ENV YOLOV5_CONFIG_DIR=/tmp/Ultralytics \
    MPLCONFIGDIR=/tmp/matplotlib \
    TORCH_HOME=/tmp/torch \
    GIT_PYTHON_REFRESH=quiet \
    YOLOv5_AUTOINSTALL=false \
    MODEL_PATH=/opt/ml/yolov5s.pt \
    YOLO_DIR=/opt/yolov5

COPY detector.py pipeline.py app.py ${LAMBDA_TASK_ROOT}/

CMD ["app.handler"]
