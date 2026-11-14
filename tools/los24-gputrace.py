#!/usr/bin/env python3
"""Summarise the ftrace part of a los24-perfprobe.sh log: GPU jobs per process
(msm_gpu_submit_retired: real execution time, clock; flush -> retire latency)
and the DRM vblank rate. Needs the msm GPU tracepoints in the kernel."""
import re, statistics as st, sys
pidname, flush, jobs, vbl, sec = {}, {}, [], [], None
for l in open(sys.argv[1], errors="replace"):
    if l.startswith("== "):
        sec = l.strip(); continue
    if sec == "== ps":
        m = re.match(r"\s*(\d+)\s+(\S+)", l)
        if m: pidname[m.group(1)] = m.group(2)
    m = re.search(r"\s([\d.]+): msm_gpu_submit_flush: id=(\d+) pid=(\d+) ring=(\d+):(\d+)", l)
    if m:
        flush[(m.group(4), m.group(5))] = float(m.group(1)); continue
    m = re.search(r"\s([\d.]+): msm_gpu_submit_retired: id=(\d+) pid=(\d+) ring=(\d+):(\d+) elapsed=(\d+) ns mhz=(\d+)", l)
    if m:
        t, k = float(m.group(1)), (m.group(4), m.group(5))
        jobs.append(dict(t=t, pid=m.group(3), el=int(m.group(6)) / 1e6, mhz=int(m.group(7)),
                         lat=(t - flush[k]) * 1e3 if k in flush else None))
        continue
    m = re.search(r"\s([\d.]+): drm_vblank_event: crtc=(\d+)", l)
    if m: vbl.append(float(m.group(1)))
if len(vbl) > 1:
    print(f"{len(vbl)} vblanks, {(len(vbl) - 1) / (vbl[-1] - vbl[0]):.1f}/s")
if not jobs:
    sys.exit("no GPU jobs in the trace (msm tracepoints missing?)")
span = jobs[-1]["t"] - jobs[0]["t"]
print(f"{span:.2f} s, {len(jobs)} GPU jobs, GPU busy {sum(j['el'] for j in jobs) / 1e3 / span * 100:.0f} %, "
      f"clock {st.median([j['mhz'] for j in jobs])} MHz median")
by = {}
for j in jobs: by.setdefault(j["pid"], []).append(j)
for p, js in sorted(by.items(), key=lambda x: -sum(j["el"] for j in x[1])):
    el = sorted(j["el"] for j in js); lat = [j["lat"] for j in js if j["lat"] is not None]
    print(f"  pid {p} {pidname.get(p, '?')[:40]:40} jobs {len(js):4}  exec median {st.median(el):6.2f} ms "
          f"p90 {el[int(len(el) * .9)]:6.2f}  flush->retire median {st.median(lat) if lat else 0:6.2f} ms")
