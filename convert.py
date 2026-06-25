import os
from PIL import Image
import numpy as np

try:
    # Read as grayscale
    img = Image.open('assets/caveira.png').convert('L')
    data = np.array(img)
    
    # Create an empty RGBA array
    rgba = np.zeros((data.shape[0], data.shape[1], 4), dtype=np.uint8)
    
    # Let's pick a threshold. The skull is very bright white.
    # Everything brighter than 150 becomes white, the rest becomes transparent.
    mask = data > 150
    rgba[mask] = [255, 255, 255, 255]
    rgba[~mask] = [0, 0, 0, 0]
    
    out = Image.fromarray(rgba)
    out.thumbnail((96, 96))
    out.save('android/app/src/main/res/drawable/ic_notification.png')
    print("SUCCESS: Image re-processed using brightness.")
except Exception as e:
    print(f"FAILED: {e}")
