#!/usr/bin/env python3
"""Seeds a big fake Photos library for performance and count tests (test plan A4: Phase P, C.1, 3.21).

  Scripts/seed-library.py make --count 40000 --out build/seed40k     generate files (once; ~1 GB for 40k)
  Scripts/seed-library.py sim  --out build/seed40k --udid <UDID>     add them to a simulator's Photos
  Scripts/seed-library.py adb  --out build/seed40k [--serial emulator-5554]   push to an emulator and scan

Photos get EXIF dates spread over 10 years (so the timeline has many months), every 7th one has GPS, every 200th
item is a 2-second video. Never seed a simulator or emulator that is signed in to a real Telegram library:
automatic backup would try to upload everything.
"""
import argparse
import os
import random
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

PLACES = [(48.8584, 2.2945), (40.6892, -74.0445), (35.6586, 139.7454), (-33.8568, 151.2153), (9.9312, 76.2673),
          (51.5007, -0.1246), (37.8199, -122.4783), (25.1972, 55.2744)]


def gps_ifd(lat, lon):
    def dms(v):
        v = abs(v)
        d = int(v); m = int((v - d) * 60)
        return (float(d), float(m), round(((v - d) * 60 - m) * 60, 2))
    return {1: "N" if lat >= 0 else "S", 2: dms(lat), 3: "E" if lon >= 0 else "W", 4: dms(lon)}


def make(count, out):
    from PIL import Image, ImageDraw
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(40_000)  # same library every time, so numbers in the test plan stay comparable
    start = datetime(2016, 1, 1)
    span = (datetime(2026, 11, 1) - start).total_seconds()
    videos = []
    for i in range(count):
        when = start + timedelta(seconds=rng.random() * span)
        if i % 200 == 199:
            videos.append((i, when))
            continue
        path = out / f"IMG_{i:05d}.jpg"
        if path.exists():
            continue
        hue = rng.randrange(360)
        img = Image.new("RGB", (480, 360), f"hsl({hue},55%,55%)")
        d = ImageDraw.Draw(img)
        d.rectangle([rng.randrange(300), rng.randrange(200), 480, 360], fill=f"hsl({(hue + 40) % 360},60%,40%)")
        d.text((16, 16), f"#{i}  {when:%Y-%m-%d}", fill="white")
        exif = Image.Exif()
        stamp = when.strftime("%Y:%m:%d %H:%M:%S")
        exif[0x0132] = stamp                       # DateTime
        exif.get_ifd(0x8769)[0x9003] = stamp       # DateTimeOriginal
        exif.get_ifd(0x8769)[0x9004] = stamp       # DateTimeDigitized
        if i % 7 == 0:
            lat, lon = PLACES[i % len(PLACES)]
            exif.get_ifd(0x8825).update(gps_ifd(lat + rng.uniform(-.01, .01), lon + rng.uniform(-.01, .01)))
        img.save(path, "JPEG", quality=70, exif=exif)
        if i % 2000 == 0:
            print(f"  {i}/{count}", flush=True)
    for i, when in videos:
        path = out / f"VID_{i:05d}.mp4"
        if path.exists():
            continue
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc=size=480x360:rate=24:duration=2",
                        "-metadata", f"creation_time={when:%Y-%m-%dT%H:%M:%S}Z", "-pix_fmt", "yuv420p", str(path)], check=True)
    print(f"Made {count - len(videos)} photos and {len(videos)} videos in {out}")


def files(out):
    return sorted(p for p in out.iterdir() if p.suffix in (".jpg", ".mp4"))


def sim(out, udid):
    batch = 400  # simctl addmedia takes a list; a few hundred per call keeps it from timing out
    all_files = files(out)
    for k in range(0, len(all_files), batch):
        subprocess.run(["xcrun", "simctl", "addmedia", udid, *map(str, all_files[k:k + batch])], check=True)
        print(f"  added {min(k + batch, len(all_files))}/{len(all_files)}", flush=True)


def adb(out, serial):
    base = ["adb", "-s", serial]
    dest = "/sdcard/DCIM/LelvoSeed"
    free = subprocess.run(base + ["shell", "df", "-k", "/sdcard"], capture_output=True, text=True).stdout.split()[-3]
    # The archive and the unpacked files are both on the device for a moment.
    need = 2 * sum(p.stat().st_size for p in files(out)) // 1024 + 200_000
    if int(free) < need:
        sys.exit(f"Not enough space on {serial}: {int(free) // 1024} MB free, about {need // 1024} MB needed")
    subprocess.run(base + ["shell", "mkdir", "-p", dest], check=True)
    # One archive: adb push of 40k small files crawls (and stalled for minutes on the emulator).
    tar = out.with_suffix(".tar")
    # COPYFILE_DISABLE: macOS tar would add a "._" metadata file next to every photo.
    subprocess.run(["tar", "-cf", str(tar), "-C", str(out), "."], check=True, env={**os.environ, "COPYFILE_DISABLE": "1"})
    subprocess.run(base + ["push", str(tar), "/sdcard/Download/lelvo-seed.tar"], check=True)
    subprocess.run(base + ["shell", f"tar -xf /sdcard/Download/lelvo-seed.tar -C {dest} && rm /sdcard/Download/lelvo-seed.tar"], check=True)
    tar.unlink()
    # MediaStore picks up new files on a scan; one broadcast per folder is enough on recent Android.
    subprocess.run(base + ["shell", "content", "call", "--uri", "content://media/external/file", "--method", "scan_volume",
                           "--arg", "external_primary"], check=False)
    print(f"Pushed {len(files(out))} files to {serial}:{dest}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["make", "sim", "adb"])
    ap.add_argument("--count", type=int, default=40_000)
    ap.add_argument("--out", type=Path, default=Path("build/seed40k"))
    ap.add_argument("--udid")
    ap.add_argument("--serial", default="emulator-5554")
    a = ap.parse_args()
    if a.cmd == "make":
        make(a.count, a.out)
    elif a.cmd == "sim":
        if not a.udid:
            sys.exit("--udid is required (xcrun simctl list devices)")
        sim(a.out, a.udid)
    else:
        adb(a.out, a.serial)


if __name__ == "__main__":
    main()
