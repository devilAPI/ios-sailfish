#!/usr/bin/env python3
"""los24-timeline.py PERFLOG T0 T1 REGEX: one time-ordered view of a
los24-perfprobe.sh trace window: atrace slices (B/E pairs, start -> end,
duration) whose name matches REGEX, between the kernel's vblank (TE/rd_ptr),
pp_tx_done (end of a command-mode transfer) and msm atomic commit events.
Example (run 29: apps waited for release fences that signalled at pp_done):
  tools/los24-timeline.py logs/los24-m1a-29-perf.txt 413.100 413.170 \\
    '^(dequeueBuffer$|queueBuffer$|composite|Commit_nonblock|waitForever)'"""
import re, sys
f,t0,t1,pat=sys.argv[1],float(sys.argv[2]),float(sys.argv[3]),re.compile(sys.argv[4])
st={};out=[]
SL=re.compile(r"^\s*(.+?)-(\d+)\s+\(\s*[\d-]+\)\s+\[\d+\]\s+\S+\s+([\d.]+): (.*)$")
for l in open(f,errors="replace"):
    m=SL.match(l)
    if not m: continue
    comm,tid,t,ev=m.group(1),m.group(2),float(m.group(3)),m.group(4)
    if t<t0-0.2 or t>t1: continue
    if ev.startswith("tracing_mark_write: B|"):
        st.setdefault(tid,[]).append((ev.split("|",2)[2],t))
    elif ev.startswith("tracing_mark_write: E|"):
        if st.get(tid):
            n,b=st[tid].pop()
            if b>=t0 and pat.search(n): out.append((b,f"{comm[:14]:14} {n[:50]:50} {b:.4f} -> {t:.4f} ({(t-b)*1e3:5.1f} ms)"))
    elif t>=t0 and re.search(r"drm_vblank|pp_tx_done: id=\d+, pp=0|commit_tail_start|dma_fence_signaled",ev):
        out.append((t,f"   ---- {t:.4f} {ev[:60]}"))
for _,s in sorted(out): print(s)
