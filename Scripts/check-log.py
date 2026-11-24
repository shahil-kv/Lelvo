#!/usr/bin/env python3
"""Checks a Lelvo app log (lelvo.log) for the house rules: no secrets, FLOOD_WAIT kept, at most two uploads at once.

Usage: Scripts/check-log.py <lelvo.log> [--max-parallel 2]
Exit code 1 when a rule is broken. Prints a short report; never prints a matched secret in full.
"""
import argparse
import re
import sys
from collections import Counter
from datetime import datetime

LINE = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:.]+Z) \[(\w+)\] (.*)$")
SECRETS = [
    ("phone number", re.compile(r"(?<![\w.])\+\d{10,15}\b")),
    ("login code", re.compile(r"\b(code|passcode)\b\D{0,12}\b\d{5,6}\b", re.I)),
    ("64-hex key", re.compile(r"\b[0-9a-fA-F]{64}\b")),
    ("32-hex (api_hash?)", re.compile(r"\b[0-9a-f]{32}\b")),
    ("remote file id", re.compile(r"\b[A-Za-z0-9_-]{40,}\b(?!\.\w{2,5}\b)")),
    ("password word", re.compile(r"\b(password|passphrase|recovery key)\s*[:=]\s*\S", re.I)),
]
FLOOD = re.compile(r"FLOOD_WAIT (\d+) s: uploads paused until (\S+)")
START = re.compile(r"Send started \(message (-?\d+)\)")
END = re.compile(r"Send ended \(message (-?\d+)")


def ts(s):
    # Android writes Instant.toString(): up to 9 fraction digits, or none. Python takes at most 6.
    s = re.sub(r"\.(\d{1,6})\d*", r".\1", s.rstrip("Z"))
    return datetime.fromisoformat(s + "+00:00")


def mask(s):
    return s[:3] + "…" + s[-2:] if len(s) > 6 else "…"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--max-parallel", type=int, default=2)
    a = ap.parse_args()

    problems, secrets, kinds = [], Counter(), Counter()
    open_sends, max_par, par_at = set(), 0, None
    pause_until, flood_count, sends = None, 0, 0

    with open(a.log, errors="replace") as f:
        for n, raw in enumerate(f, 1):
            m = LINE.match(raw.rstrip("\n"))
            if not m:
                continue
            t, level, msg = ts(m[1]), m[2], m[3]
            for name, rx in SECRETS:
                hit = rx.search(msg)
                if hit:
                    secrets[name] += 1
                    if secrets[name] <= 3:
                        problems.append(f"line {n}: possible {name} ({mask(hit.group(0))})")
            if fm := FLOOD.search(msg):
                flood_count += 1
                until = ts(fm[2])
                pause_until = max(pause_until, until) if pause_until else until
            if sm := START.search(msg):
                sends += 1
                if pause_until and t < pause_until:
                    problems.append(f"line {n}: upload started {(pause_until - t).total_seconds():.0f} s inside a FLOOD_WAIT")
                open_sends.add(sm[1])
                if len(open_sends) > max_par:
                    max_par, par_at = len(open_sends), n
            if em := END.search(msg):
                open_sends.discard(em[1])
            if "Log opened for a new app process" in msg:
                open_sends.clear()  # a relaunch ends every send the old process had open
            if level in ("ERROR", "WARN"):
                kinds[f"{level} {re.sub(r'[0-9]+', '#', msg)[:90]}"] += 1

    if max_par > a.max_parallel:
        problems.append(f"line {par_at}: {max_par} uploads at once (limit {a.max_parallel})")

    print(f"Log: {a.log}")
    print(f"Sends: {sends}, most at once: {max_par}, FLOOD_WAITs: {flood_count}")
    print("Secrets: " + (", ".join(f"{k} ×{v}" for k, v in secrets.items()) or "none"))
    if kinds:
        print("Errors and warnings by kind:")
        for k, v in kinds.most_common(15):
            print(f"  {v:>5}  {k}")
    if problems:
        print("PROBLEMS:")
        for p in problems[:40]:
            print("  " + p)
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
