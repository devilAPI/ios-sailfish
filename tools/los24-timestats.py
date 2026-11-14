#!/usr/bin/env python3
"""Summarise `dumpsys SurfaceFlinger --timestats -dump` (or a los24-perfprobe.sh
log): frame counts and the medians of the histograms that matter for jank.
  presentToPresent / present2present: how often the screen changes
  post2acquire: queueBuffer -> GPU done of the app's buffer
  renderEngineTiming: SurfaceFlinger's own GPU composition"""
import re, sys
KEEP = ("presentToPresent", "present2present", "post2acquire", "renderEngineTiming",
        "acquire2present", "latch2present", "desired2present")
want = None
for line in (open(sys.argv[1], errors="replace") if len(sys.argv) > 1 else sys.stdin):
    s = line.strip()
    m = re.match(r"(\w+) histogram is as below:", s)
    if m:
        want = m.group(1)
        continue
    if want and s.startswith("0ms="):
        h = [(int(k), int(v)) for k, v in re.findall(r"(\d+)ms=(\d+)", s) if int(v)]
        n = sum(v for _, v in h)
        acc, med = 0, None
        for k, v in h:
            acc += v
            if med is None and acc >= n / 2:
                med = k
        if want in KEEP:
            print(f"  {want}: median {med} ms (n={n})")
        want = None
    elif re.match(r"(totalFrames|missedFrames|clientCompositionFrames|layerName|averageFPS) =", s):
        print(" ", s)
