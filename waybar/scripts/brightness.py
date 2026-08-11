#!/usr/bin/env python3
"""Brightness for the Control Center's two sliders — internal panel and external monitor.

    brightness.py get          -> {"internal": {...}, "external": {...}}
    brightness.py set internal 60
    brightness.py set external 60

Two very different mechanisms behind one interface:

**Internal** is a sysfs backlight via `brightnessctl` — instant, no caching needed.

**External** is DDC/CI over the monitor's I2C bus via `ddcutil`, which is slow (a `detect`
sweep takes a second or more) and does not tolerate being hammered. So the bus number is
cached after the first detect and reused; only a `--redetect` or a missing cache pays for
the sweep again. Reads and writes then go straight to that bus.

`~/.local/bin/cosmic-ddc-brightness` already existed here but only steps up/down by 5,
which a slider cannot use — it needs absolute get/set.

`get` runs once, when the Control Center opens. Nothing polls it: while the panel is
up the slider is the authority on the current value, and the percentage next to it is
read off the handle rather than off a fresh `get`.
"""

import json
import os
import re
import shutil
import subprocess
import sys

CACHE_DIR = os.path.expanduser("~/.cache/waybar-control-center")
BUS_CACHE = os.path.join(CACHE_DIR, "ddc-bus.json")
VCP_BRIGHTNESS = "10"


def run(args, timeout=10):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return out.stdout if out.returncode == 0 else ""
    except Exception:
        return ""


# --------------------------------------------------------------------------
# internal panel
# --------------------------------------------------------------------------

def internal_get():
    if not shutil.which("brightnessctl"):
        return None
    # -m is the machine-readable form: "device,class,current,percent%,max"
    parts = run(["brightnessctl", "-m"]).strip().split(",")
    if len(parts) < 4:
        return None
    try:
        return {"percent": int(parts[3].rstrip("%")), "device": parts[0]}
    except ValueError:
        return None


def internal_set(percent):
    if shutil.which("brightnessctl"):
        # Never let a slider reach 0 - a black panel with no way to see the
        # slider you would need to drag back up.
        run(["brightnessctl", "set", f"{max(1, min(100, percent))}%"], timeout=5)


# --------------------------------------------------------------------------
# external monitor (DDC/CI)
# --------------------------------------------------------------------------

def detect_buses():
    """I2C bus numbers of DDC-capable displays. Slow — the result is cached."""
    buses = []
    valid = False
    for line in run(["ddcutil", "detect", "--brief"], timeout=20).splitlines():
        if line.startswith("Display "):
            valid = True
        elif line.startswith("Invalid display"):
            valid = False
        elif "I2C bus:" in line and valid:
            match = re.search(r"i2c-(\d+)", line)
            if match:
                buses.append(match.group(1))
    return buses


def cached_buses(redetect=False):
    if not redetect:
        try:
            with open(BUS_CACHE) as f:
                cached = json.load(f)
            if cached:
                return cached
        except Exception:
            pass

    buses = detect_buses()
    os.makedirs(CACHE_DIR, exist_ok=True)
    try:
        with open(BUS_CACHE, "w") as f:
            json.dump(buses, f)
    except Exception:
        pass
    return buses


def external_get(redetect=False):
    if not shutil.which("ddcutil"):
        return None
    buses = cached_buses(redetect)
    if not buses:
        return None

    # Report the first monitor; setting applies to all of them, which is what
    # you want with one slider and is what cosmic-ddc-brightness did too.
    out = run(["ddcutil", "--bus", buses[0], "getvcp", VCP_BRIGHTNESS, "--brief"], timeout=10)
    # Brief form: "VCP 10 C <current> <max>"
    fields = out.split()
    if len(fields) >= 5 and fields[0] == "VCP":
        try:
            current, maximum = int(fields[3]), int(fields[4])
            return {
                "percent": round(100 * current / maximum) if maximum else None,
                "buses": buses,
            }
        except ValueError:
            pass
    return {"percent": None, "buses": buses}


def external_set(percent):
    if not shutil.which("ddcutil"):
        return
    for bus in cached_buses():
        run(["ddcutil", "--bus", bus, "setvcp", VCP_BRIGHTNESS,
             str(max(0, min(100, percent)))], timeout=10)


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "get"

    if action == "set" and len(sys.argv) >= 4:
        target, value = sys.argv[2], int(float(sys.argv[3]))
        if target == "internal":
            internal_set(value)
        elif target == "external":
            external_set(value)
        raise SystemExit(0)

    print(json.dumps({
        "internal": internal_get(),
        "external": external_get(redetect="--redetect" in sys.argv),
    }))
