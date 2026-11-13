#!/usr/bin/env python3
"""Build a small Google Takeout for checking the importer.

Writes two zips into the output directory (build/takeout-fixture by default):

  takeout-001.zip
    50 photos under Takeout/Google Photos/Photos from 2019/
      IMG_0001.jpg … IMG_0045.jpg have a sidecar (date, and a place on the first ten;
      IMG_0001 is a favourite)
      IMG_0046.jpg … IMG_0048.jpg and IMG_0050.jpg have no sidecar in this zip
      IMG_0050.jpg's sidecar is in the second zip
      IMG_0049.jpg is a Live Photo (paired with IMG_0049.MOV) and has a sidecar
    the same IMG_0001.jpg again in an album folder "Goa", with metadata.json
    notes.pdf, which is not a photo
  takeout-002.zip
    the sidecar for IMG_0050.jpg

The MOV is a tiny container so the Live Photo pairs. It is not a playable video.
"""

import argparse
import base64
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
YEAR = "Takeout/Google Photos/Photos from 2019"
ALBUM = "Takeout/Google Photos/Goa"
STAMP = (2019, 7, 4, 18, 22, 0)

# 1×1 JPEG. A comment is inserted so each photo has its own size and CRC.
TINY_JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"
    "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAA//aAAgBAQABPxA="
)


def jpeg(n: int) -> bytes:
    comment = f"photo-{n:04d}".encode()
    segment = b"\xff\xfe" + (len(comment) + 2).to_bytes(2, "big") + comment
    body = TINY_JPEG
    if body.endswith(b"\xff\xd9"):
        body = body[:-2]
    return body + segment + b"\xff\xd9"


def mov(n: int) -> bytes:
    brand = b"qt  "
    ftyp_body = brand + b"\x00\x00\x00\x00" + brand
    ftyp = (8 + len(ftyp_body)).to_bytes(4, "big") + b"ftyp" + ftyp_body
    payload = f"live-{n:04d}".encode()
    free = (8 + len(payload)).to_bytes(4, "big") + b"free" + payload
    return ftyp + free


def sidecar(title: str, when: int, place: bool, favorite: bool) -> bytes:
    if place:
        geo = {"latitude": 15.299326, "longitude": 74.124008, "altitude": 12.0}
    else:
        geo = {"latitude": 0.0, "longitude": 0.0, "altitude": 0.0}
    body = {
        "title": title,
        "photoTakenTime": {"timestamp": str(when)},
        "geoData": geo,
        "geoDataExif": {"latitude": 0.0, "longitude": 0.0, "altitude": 0.0},
        "favorited": favorite,
    }
    return json.dumps(body).encode()


def add(zf: zipfile.ZipFile, path: str, data: bytes) -> None:
    info = zipfile.ZipInfo(path, STAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(info, data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default=str(ROOT / "build" / "takeout-fixture"))
    args = parser.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    photos = {n: jpeg(n) for n in range(1, 51)}
    first = out / "takeout-001.zip"
    with zipfile.ZipFile(first, "w") as zf:
        for n, data in photos.items():
            name = f"IMG_{n:04d}.jpg"
            add(zf, f"{YEAR}/{name}", data)
            # 46–50 have no sidecar in this zip. 50's sidecar is in the second zip.
            if n <= 45:
                when = 1_562_250_000 + n * 3600
                add(zf, f"{YEAR}/{name}.json", sidecar(name, when, place=n <= 10, favorite=n == 1))
        add(zf, f"{YEAR}/IMG_0049.MOV", mov(49))
        add(zf, f"{YEAR}/IMG_0049.jpg.json", sidecar("IMG_0049.jpg", 1_562_250_000 + 49 * 3600, place=True, favorite=False))
        add(zf, f"{YEAR}/notes.pdf", b"%PDF-1.1\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n")
        add(zf, f"{ALBUM}/metadata.json", json.dumps({"title": "Goa"}).encode())
        add(zf, f"{ALBUM}/IMG_0001.jpg", photos[1])

    second = out / "takeout-002.zip"
    with zipfile.ZipFile(second, "w") as zf:
        add(zf, f"{YEAR}/IMG_0050.jpg.json", sidecar("IMG_0050.jpg", 1_562_250_000 + 50 * 3600, place=True, favorite=False))

    print(f"Wrote {first}")
    print(f"Wrote {second}")
    print("50 photos in the first zip (IMG_0049 is a Live Photo), 1 album copy, 1 PDF, 1 sidecar in the second zip.")


if __name__ == "__main__":
    main()
