#!/usr/bin/env python3
"""Summarise the ftrace part of a los24-perfprobe.sh log: GPU jobs per process
(msm_gpu_submit_retired: real execution time, clock; flush -> retire latency),
the DRM vblank rate, msm atomic commit and DPU command-mode event timing, and
atrace slices (tracing_mark_write B/E: HWUI dequeueBuffer/queueBuffer/DrawFrame,
SurfaceFlinger commit/composite) per process."""
import re, statistics as st, sys
pidname, flush, jobs, vbl, sec = {}, {}, [], [], None
kev = {}                    # kernel event name -> [timestamps]
stacks, slices = {}, {}     # tid -> [(name, t)]; (pid, name) -> [ms]
SL = re.compile(r"-(\d+)\s+\(\s*(\d+|-+)\).*?\s([\d.]+): tracing_mark_write: ([BE])\|(\d+)(?:\|([^|\n]*))?")
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
    if m: vbl.append(float(m.group(1))); continue
    m = SL.search(l)
    if m:
        tid, t, ph, pid, name = m.group(1), float(m.group(3)), m.group(4), m.group(5), (m.group(6) or "").strip()
        st_ = stacks.setdefault(tid, [])
        if ph == "B":
            st_.append((pid, name, t))
        elif st_:
            bp, bn, bt = st_.pop()
            slices.setdefault((bp, re.sub(r"\s*[\d#]+$", "", bn)[:48]), []).append((t - bt) * 1e3)
        continue
    m = re.search(r"\s([\d.]+): ((?:msm_atomic|dpu)_\w+):", l)
    if m: kev.setdefault(m.group(2), []).append(float(m.group(1)))
if len(vbl) > 1:
    print(f"{len(vbl)} vblanks, {(len(vbl) - 1) / (vbl[-1] - vbl[0]):.1f}/s")
def ms(v): return f"median {st.median(v):6.2f} p90 {sorted(v)[int(len(v) * .9)]:6.2f} max {max(v):6.2f} ms"
for e, ts in sorted(kev.items()):
    rate = f"{(len(ts) - 1) / (ts[-1] - ts[0]):.1f}/s" if len(ts) > 1 and ts[-1] > ts[0] else ""
    print(f"{e:40} {len(ts):5} events {rate}")
for a, b in (("msm_atomic_commit_tail_start", "msm_atomic_commit_tail_finish"),
             ("msm_atomic_wait_flush_start", "msm_atomic_wait_flush_finish"),
             ("dpu_enc_trigger_flush", "dpu_enc_phys_cmd_pp_tx_done")):
    A, B = kev.get(a, []), kev.get(b, [])
    d = [(min((y for y in B if y >= x), default=x) - x) * 1e3 for x in A]
    d = [v for v in d if v > 0]
    if d: print(f"  {a} -> {b}: {ms(d)}")
KEEP = re.compile(r"dequeueBuffer|queueBuffer|DrawFrame|flush commands|eglSwapBuffers|waitForGpu|"
                  r"Fence|fence|commit|composite|onMessageInvalidate|onMessageRefresh|"
                  r"presentAndGetReleaseFences|validate|RenderEngine|drawLayers|Choreographer#doFrame", re.I)
if slices:
    print("atrace slices (pid name: count, duration)")
    for (p, n), v in sorted(slices.items(), key=lambda x: -sum(x[1])):
        if KEEP.search(n) and len(v) >= 5:
            print(f"  {pidname.get(p, p)[:28]:28} {n[:44]:44} {len(v):5}  {ms(v)}")
if not jobs:
    sys.exit("no GPU jobs in the trace (msm tracepoints missing?)")
span = max(jobs[-1]["t"] - jobs[0]["t"], 1e-3)
print(f"{span:.2f} s, {len(jobs)} GPU jobs, GPU busy {sum(j['el'] for j in jobs) / 1e3 / span * 100:.0f} %, "
      f"clock {st.median([j['mhz'] for j in jobs])} MHz median")
by = {}
for j in jobs: by.setdefault(j["pid"], []).append(j)
for p, js in sorted(by.items(), key=lambda x: -sum(j["el"] for j in x[1])):
    el = sorted(j["el"] for j in js); lat = [j["lat"] for j in js if j["lat"] is not None]
    print(f"  pid {p} {pidname.get(p, '?')[:40]:40} jobs {len(js):4}  exec median {st.median(el):6.2f} ms "
          f"p90 {el[int(len(el) * .9)]:6.2f}  flush->retire median {st.median(lat) if lat else 0:6.2f} ms")
