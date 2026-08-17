#!/usr/bin/env python3
"""System usage for the Control Center, as one JSON blob.

Waybar's cpu/memory/disk modules each render a number and nothing else - no
history, no rates, no temperature. Rather than adding four more of them, the
Control Center shows one block fed from here.

Two of these figures are rates, not readings, and rates need two samples:

  CPU     sampled inline over a short window. /proc/stat counts jiffies since
          boot, so a single read gives average utilisation since power-on -
          which is a number that barely moves and tells you nothing.

  Network counters are cumulative bytes, so the delta is taken against the
          previous invocation via a small cache file. A 0.2s inline window like
          the CPU's would be far too short to characterise throughput.
"""

import json
import os
import shutil
import time

CACHE_DIR = os.path.expanduser("~/.cache/hyprbar")
NET_CACHE = os.path.join(CACHE_DIR, "system-stats-net.json")
CPU_SAMPLE_SECONDS = 0.2


def read_cpu_jiffies():
    with open("/proc/stat") as f:
        parts = f.readline().split()
    values = [int(v) for v in parts[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def cpu_percent():
    try:
        total_a, idle_a = read_cpu_jiffies()
        time.sleep(CPU_SAMPLE_SECONDS)
        total_b, idle_b = read_cpu_jiffies()
        d_total = total_b - total_a
        if d_total <= 0:
            return None
        return round(100 * (1 - (idle_b - idle_a) / d_total), 1)
    except Exception:
        return None


def memory():
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                key, _, rest = line.partition(":")
                info[key] = int(rest.split()[0]) * 1024
        total = info.get("MemTotal", 0)
        available = info.get("MemAvailable", 0)
        swap_total = info.get("SwapTotal", 0)
        swap_free = info.get("SwapFree", 0)
        return {
            "total": total,
            # MemAvailable, not MemFree: Linux uses everything spare for cache,
            # so MemFree on a healthy machine is alarmingly small and means
            # nothing.
            "used": total - available,
            "percent": round(100 * (total - available) / total, 1) if total else None,
            "swap_total": swap_total,
            "swap_used": swap_total - swap_free,
            "swap_percent": round(100 * (swap_total - swap_free) / swap_total, 1)
                            if swap_total else None,
        }
    except Exception:
        return None


def disk(path="/"):
    try:
        usage = shutil.disk_usage(path)
        return {
            "total": usage.total,
            "used": usage.used,
            "percent": round(100 * usage.used / usage.total, 1) if usage.total else None,
        }
    except Exception:
        return None


def network():
    """Per-interface byte rates, against the previous call's counters."""
    try:
        now = time.time()
        current = {}
        with open("/proc/net/dev") as f:
            for line in f.readlines()[2:]:
                name, _, rest = line.partition(":")
                name = name.strip()
                if name == "lo" or name.startswith(("veth", "docker", "br-")):
                    continue
                fields = rest.split()
                current[name] = {"rx": int(fields[0]), "tx": int(fields[8])}

        previous = {}
        try:
            with open(NET_CACHE) as f:
                previous = json.load(f)
        except Exception:
            pass

        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(NET_CACHE, "w") as f:
            json.dump({"at": now, "ifaces": current}, f)

        elapsed = now - previous.get("at", 0)
        # A stale cache would divide a huge byte delta by a huge elapsed time
        # and report a plausible-looking average that describes nothing.
        if not previous or elapsed <= 0 or elapsed > 60:
            return {"rx_rate": None, "tx_rate": None, "interfaces": list(current)}

        rx = tx = 0
        for name, counters in current.items():
            was = previous["ifaces"].get(name)
            if not was:
                continue
            rx += max(0, counters["rx"] - was["rx"])
            tx += max(0, counters["tx"] - was["tx"])

        return {
            "rx_rate": round(rx / elapsed),
            "tx_rate": round(tx / elapsed),
            "interfaces": list(current),
        }
    except Exception:
        return None


def temperature():
    """The warmest CPU-ish sensor, which is the one worth showing."""
    best = None
    try:
        base = "/sys/class/hwmon"
        for entry in os.listdir(base):
            path = os.path.join(base, entry)
            try:
                with open(os.path.join(path, "name")) as f:
                    name = f.read().strip()
            except Exception:
                continue
            if name not in ("coretemp", "k10temp", "zenpower", "acpitz"):
                continue
            for sensor in os.listdir(path):
                if not (sensor.startswith("temp") and sensor.endswith("_input")):
                    continue
                try:
                    with open(os.path.join(path, sensor)) as f:
                        celsius = int(f.read().strip()) / 1000
                except Exception:
                    continue
                if best is None or celsius > best:
                    best = celsius
    except Exception:
        return None
    return round(best, 1) if best is not None else None


def fans():
    """Fan RPMs from `sensors -j`.

    Not read from /sys/class/hwmon directly: on this machine the fans live under
    a platform driver that exposes no fan*_input files there, so a sysfs sweep
    finds nothing while lm-sensors reports both fans fine. The acpi_fan chip is
    skipped because it duplicates the first real fan.
    """
    if not shutil.which("sensors"):
        return None
    try:
        data = json.loads(run(["sensors", "-j"]) or "{}")
    except Exception:
        return None

    found = []
    for chip, readings in data.items():
        if chip.startswith("acpi_fan"):
            continue
        for label, values in readings.items():
            if not isinstance(values, dict):
                continue
            for key, rpm in values.items():
                if key.endswith("_input") and key.startswith("fan") and rpm:
                    found.append({"label": label.replace("fan", "Fan "), "rpm": int(rpm)})
    return found or None


def uptime():
    try:
        with open("/proc/uptime") as f:
            return int(float(f.readline().split()[0]))
    except Exception:
        return None


def load():
    try:
        return [round(v, 2) for v in os.getloadavg()]
    except Exception:
        return None


def tools():
    """State for the quick-action tiles that moved off the bar's tools drawer.

    Both of these are cheap enough to re-read on the panel's normal tick. The
    update count is deliberately NOT here - `checkupdates` hits the package
    databases and takes seconds, so the panel polls that on its own slow timer.
    """
    state = {"idle_inhibited": None, "power_profile": None}

    hypridle = os.path.expanduser("~/.config/hypr/scripts/hypridle.sh")
    if os.path.exists(hypridle):
        try:
            # The script reports waybar-shaped JSON: class "active" means
            # hypridle is running, i.e. the screen is NOT being kept awake.
            payload = json.loads(run([hypridle, "status"]) or "{}")
            state["idle_inhibited"] = payload.get("class") != "active"
        except Exception:
            pass

    if shutil.which("powerprofilesctl"):
        profile = run(["powerprofilesctl", "get"]).strip()
        state["power_profile"] = profile or None

    # The four toggles swaync's own buttons-grid carries, so the Control Center
    # is a superset of the panel it replaces on the bar.
    if shutil.which("nmcli"):
        state["wifi_enabled"] = run(["nmcli", "radio", "wifi"]).strip() == "enabled"

    if shutil.which("rfkill"):
        # "Soft blocked: yes" on every bluetooth line means the radio is off.
        lines = [l for l in run(["rfkill", "list", "bluetooth"]).splitlines()
                 if "Soft blocked" in l]
        state["bluetooth_enabled"] = bool(lines) and not all("yes" in l for l in lines)

    if shutil.which("wpctl"):
        state["muted"] = "[MUTED]" in run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])

    # Notification count and DND used to be polled here out of swaync-client.
    # Quickshell is the notification daemon now, so that state lives in the
    # NotificationState singleton and the Control Center reads it directly —
    # no subprocess, and no polling interval to lag behind.

    return state


def run(args):
    import subprocess
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=4)
        return out.stdout if out.returncode == 0 else ""
    except Exception:
        return ""


if __name__ == "__main__":
    print(json.dumps({
        "tools": tools(),
        "cpu": cpu_percent(),
        "memory": memory(),
        "disk": disk(),
        "network": network(),
        "temperature": temperature(),
        "fans": fans(),
        "uptime": uptime(),
        "load": load(),
        "cores": os.cpu_count(),
    }))
