#!/usr/bin/env python3
"""Puts every PNG in a folder onto one image, in name order, to review a screen tour at a glance.
   python3 Scripts/contact-sheet.py build/tour/light build/tour/light.png [columns]"""
import sys, glob, os
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
cols = int(sys.argv[3]) if len(sys.argv) > 3 else 5
files = sorted(glob.glob(os.path.join(src, '*.png')))
if not files: sys.exit('no screenshots in ' + src)
w = 300
thumbs = []
for f in files:
    im = Image.open(f).convert('RGB'); im = im.resize((w, int(im.height * w / im.width)))
    thumbs.append(im)
h = max(t.height for t in thumbs)
rows = (len(thumbs) + cols - 1) // cols
sheet = Image.new('RGB', (cols * (w + 10) + 10, rows * (h + 10) + 10), (128, 128, 128))
for i, t in enumerate(thumbs):
    sheet.paste(t, (10 + (i % cols) * (w + 10), 10 + (i // cols) * (h + 10)))
sheet.save(out)
print(out, len(files), 'screens')
