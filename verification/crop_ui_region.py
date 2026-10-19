import sys
from PIL import Image

source, destination = sys.argv[1], sys.argv[2]
image = Image.open(source).convert("RGB")
if image.size != (1500, 1000):
    image = image.resize((1500, 1000))
# Header action buttons: no clock, no conversation content, stable across runs.
image.crop((360, 0, 1130, 60)).save(destination)
print(f"cropped {source} -> {destination}")
