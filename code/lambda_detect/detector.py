"""YOLOv5 wrapper shared by the Lambda function and the EC2 (no-Lambda) server.

The model is loaded once per process (Lambda execution environment) and reused
for every request, so only the first request in a new environment pays the
model-load cost (the "cold start").
"""
import io
import os
import time

import torch
from PIL import Image, ImageDraw, ImageFont, ImageOps

# 20 distinct colours, cycled by class id, so the same class always gets the same colour.
PALETTE = [
    (255, 56, 56), (255, 157, 151), (255, 112, 31), (255, 178, 29), (207, 210, 49),
    (72, 249, 10), (146, 204, 23), (61, 219, 134), (26, 147, 52), (0, 212, 187),
    (44, 153, 168), (0, 194, 255), (52, 69, 147), (100, 115, 255), (0, 24, 236),
    (132, 56, 255), (82, 0, 133), (203, 56, 255), (255, 149, 200), (255, 55, 199),
]


class Detector:
    def __init__(self, weights, repo_dir, conf=0.25, iou=0.45):
        torch.set_num_threads(max(1, os.cpu_count() or 1))
        # source='local' loads hubconf.py from the YOLOv5 repo baked into the image:
        # no network access is needed at run time.
        self.model = torch.hub.load(repo_dir, "custom", path=weights, source="local", verbose=False)
        self.model.conf = conf
        self.model.iou = iou
        self.names = self.model.names
        self.font = ImageFont.load_default()

    def detect(self, image_bytes, size=640):
        """Return (objects, annotated_jpeg_bytes, inference_ms, (width, height))."""
        img = Image.open(io.BytesIO(image_bytes))
        img = ImageOps.exif_transpose(img).convert("RGB")

        start = time.perf_counter()
        with torch.inference_mode():
            results = self.model(img, size=size)
        inference_ms = round((time.perf_counter() - start) * 1000, 1)

        objects = []
        for x1, y1, x2, y2, conf, cls in results.xyxy[0].tolist():
            objects.append({
                "label": self.names[int(cls)],
                "class_id": int(cls),
                "confidence": round(conf, 4),
                "box": [round(x1, 1), round(y1, 1), round(x2, 1), round(y2, 1)],
            })

        return objects, self._annotate(img, objects), inference_ms, img.size

    def _annotate(self, img, objects):
        draw = ImageDraw.Draw(img)
        width = max(2, img.width // 300)
        for obj in objects:
            x1, y1, x2, y2 = obj["box"]
            colour = PALETTE[obj["class_id"] % len(PALETTE)]
            draw.rectangle([x1, y1, x2, y2], outline=colour, width=width)
            text = f'{obj["label"]} {obj["confidence"]:.2f}'
            tx1, ty1, tx2, ty2 = draw.textbbox((x1, y1), text, font=self.font)
            top = max(0, y1 - (ty2 - ty1) - 4)
            draw.rectangle([x1, top, x1 + (tx2 - tx1) + 6, top + (ty2 - ty1) + 4], fill=colour)
            draw.text((x1 + 3, top + 1), text, fill=(255, 255, 255), font=self.font)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=90)
        return buf.getvalue()
