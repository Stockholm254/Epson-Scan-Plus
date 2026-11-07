#!/usr/bin/env python3
# Drives the app's camera process over the camera's own PTP (`EpsonScanPlus --sony-ptp-camera`)
# against the real camera, one step after another, and logs every event with its time: for trying
# the PTP link on the copy stand without the app's window. The camera must be on, in PC Remote, and
# free (Lightroom, Capture One, Imaging Edge and this app quit).
#   Tools/ptp-camera-drive.py "<app>/Contents/MacOS/EpsonScanPlus" OUTDIR props shift live switch:16 switch:4 shoot:4 af restore
import json, os, subprocess, sys, threading, time

binary, out = sys.argv[1], sys.argv[2]
steps = sys.argv[3:] or ["props", "shift", "live"]
incoming = os.path.join(out, "Incoming"); live = os.path.join(out, "Live")
os.makedirs(incoming, exist_ok=True); os.makedirs(live, exist_ok=True)
log = open(os.path.join(out, "events.log"), "a")
t0 = time.time()
events, lock = [], threading.Condition()
p = subprocess.Popen([binary, "--sony-ptp-camera"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

def note(s):
    line = "%7.2f %s" % (time.time() - t0, s)
    print(line, flush=True); log.write(line + "\n"); log.flush()

frames = [0]
def reader():
    for line in p.stdout:
        line = line.rstrip("\n")
        try: e = json.loads(line)
        except Exception: note("?? " + line); continue
        if e.get("event") == "frame":
            frames[0] += 1
            if frames[0] % 20 == 1: note("frame #%d %s" % (frames[0], e.get("path")))
        elif e.get("event") == "props":
            for item in e["props"]:
                note("  prop %-28s %-14s settable=%s values=%s" % (item["name"], item["value"], item["settable"], item["values"][:12]))
        else:
            note("<- " + line)
        with lock: events.append(e); lock.notify_all()
    note("process ended")
threading.Thread(target=reader, daemon=True).start()

def send(o):
    note("-> " + json.dumps(o, ensure_ascii=False)); p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()

def wait(pred, seconds):
    end = time.time() + seconds
    with lock:
        while time.time() < end:
            for e in events:
                if pred(e): events.remove(e); return e
            lock.wait(0.1)
    return None

send({"cmd": "connect", "save": incoming, "card": False})
c = wait(lambda e: e.get("event") in ("connected", "error"), 20)
if not c or c.get("event") != "connected":
    note("no connection"); p.kill(); sys.exit(1)
original = {}
for step in steps:
    if step == "props":
        send({"cmd": "props"}); e = wait(lambda e: e.get("event") == "props", 10)
        if e and not original: original = {i["name"]: i["value"] for i in e["props"]}
    elif step == "shift":
        send({"cmd": "shift"}); e = wait(lambda e: e.get("event") == "shift", 10)
        if e and "shift" not in original: original["shift"] = e.get("shots")
    elif step == "live":
        send({"cmd": "live", "on": True, "dir": live}); before = frames[0]; time.sleep(4)
        note("live: %d frames in 4 s" % (frames[0] - before))
    elif step.startswith("switch:"):
        n = int(step.split(":")[1]); before = frames[0]
        send({"cmd": "shift", "count": n}); e = wait(lambda e: e.get("event") == "shift", 15)
        note("switch to %d answered %s; frames meanwhile %d" % (n, e and e.get("shots"), frames[0] - before))
    elif step.startswith("shoot"):
        n = int(step.split(":")[1]) if ":" in step else 1
        send({"cmd": "shoot", "mf": True}); wait(lambda e: e.get("event") == "shot", 20)
        got = 0
        while got < n:
            e = wait(lambda e: e.get("event") == "downloaded", 30)
            if not e: break
            got += 1
        note("shoot: %d of %d pictures" % (got, n))
    elif step == "af":
        send({"cmd": "af", "afs": False, "hold": True}); wait(lambda e: e.get("event") == "af", 15)
    elif step == "restore":
        if "shift" in original:
            send({"cmd": "shift", "count": original["shift"]}); wait(lambda e: e.get("event") == "shift", 15)
        if "FocusMode" in original:
            send({"cmd": "set", "name": "FocusMode", "value": original["FocusMode"]}); wait(lambda e: e.get("event") == "set", 10)
            time.sleep(1.5); send({"cmd": "props"}); wait(lambda e: e.get("event") == "props", 10)
    elif step.startswith("sleep:"):
        time.sleep(float(step.split(":")[1]))
send({"cmd": "disconnect"}); wait(lambda e: e.get("event") == "disconnected", 10)
p.wait(timeout=10); note("exit %s" % p.returncode)
