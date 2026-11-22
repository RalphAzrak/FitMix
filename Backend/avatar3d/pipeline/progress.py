"""Turns the model generator's own log into overall build progress.

Reads trellis-cli's output on stdin, copies it to the log file, and prints "PROGRESS <percent>" whenever the build
moves on. The generator reports each stage and every sampler step, so the percentage follows real work.
Usage: trellis-cli ... 2>&1 | progress.py trellis.log <first percent> <last percent>"""
import re
import sys

log_path, first, last = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
# Where each generator stage starts, and how much of the whole shape step its 12 sampler steps cover.
# Measured on an M5: the first flow is about two thirds of the time.
STAGES = [
    ("preprocess", 0.00, 0.0), ("DINOv3", 0.01, 0.0), ("sparse-structure flow", 0.03, 0.64),
    ("shape SLAT flow", 0.68, 0.14), ("shape decode", 0.83, 0.0), ("texture SLAT flow", 0.85, 0.09), ("write", 0.95, 0.0),
]
start, span, shown = 0.0, 0.0, -1

def report(fraction):
    global shown
    percent = int(first + (last - first) * min(max(fraction, 0.0), 1.0))
    if percent > shown:
        shown = percent
        print(f"PROGRESS {percent}", flush=True)

with open(log_path, "w") as log:
    for line in sys.stdin:
        log.write(line); log.flush()
        stage = re.match(r"\[\d/\d\] (.*)", line)
        if stage:
            for name, begins, steps in STAGES:
                if name in stage.group(1):
                    start, span = begins, steps
                    report(start)
            continue
        step = re.search(r"\[flow\] \[[#.]+\]\s+(\d+)/(\d+)", line)
        if step and span:
            report(start + span * int(step.group(1)) / int(step.group(2)))
        elif line.startswith("done in"):
            report(1.0)
