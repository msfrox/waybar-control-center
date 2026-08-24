#!/usr/bin/env python3
"""Network throughput for the Network menu, as one JSON blob.

    {"interfaces": ["wlan0", "tailscale0"], "default": "wlan0",
     "by_iface": {
         "wlan0": {"rx_rate": 612, "tx_rate": 931, "rx_total": 1362157880,
                    "tx_total": 1664719912, "top_rx": 3753000, "top_tx": 204800,
                    "history": {"rx": [...], "tx": [...]}},
         "tailscale0": {...},
         "total": {...}   -- sum across every interface above
     }}

Deliberately separate from system-stats.py's own network() reader, even though
both parse /proc/net/dev the same way: that one runs on the Control Center's
2s tick only while the Control Center is open, this one is meant to run on the
Network menu's own tick instead, and sharing one cache file between two
independent pollers would make each one's rate delta and history depend on
when the OTHER window last happened to poll. Cheap enough (pure file reads, no
subprocess) that a second copy costs nothing.

EVERY INTERFACE IS TRACKED SEPARATELY, "total" INCLUDED. The first version
picked one interface automatically (the default route) because summing
everything double-counted: Tailscale's traffic is a WireGuard tunnel carried
inside wlan0's own packets, so tailscale0 and wlan0 both counted the same
bytes and the combined total ran well above what btop (which watches one
interface) reported for the same session. That's still true of "total" here -
it is a sum across whatever interfaces are up, tunnels included, so it isn't a
count of physical bytes either - but hiding the other interfaces entirely was
the wrong tradeoff once there's a picker in the UI to choose among them. Let
the person looking at it decide what "total" should mean; report the pieces
so the arithmetic is honest either way. `default` names the default-route
interface as the picker's initial selection - everything else is provided but
not pre-selected.

Per interface (and for the "total" pseudo-interface):

  rx_rate / tx_rate   instantaneous, from the delta against the previous call
  rx_total / tx_total kernel's raw cumulative counters, since the interface
                       came up (effectively since boot for anything that
                       hasn't been unplugged) - free from the same read, no
                       state needed. For "total", the sum of the real
                       interfaces' totals.
  top_rx / top_tx      the highest rate this interface has ever been observed
                       at, carried in the cache file so it survives calls
  history              a rolling window of recent rates for the sparkline,
                       also carried in the cache file
"""

import json
import os
import time

CACHE_DIR = os.path.expanduser("~/.cache/hyprbar")
CACHE_FILE = os.path.join(CACHE_DIR, "network-throughput.json")
# 150 samples at the 2s poll interval below = 5 minutes of graph.
HISTORY_LEN = 150
TOTAL_KEY = "total"


def read_interfaces():
    current = {}
    with open("/proc/net/dev") as f:
        for line in f.readlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            if name == "lo" or name.startswith(("veth", "docker", "br-")):
                continue
            fields = rest.split()
            current[name] = {"rx": int(fields[0]), "tx": int(fields[8])}
    return current


def default_interface():
    """The interface the kernel would send an internet-bound packet out of."""
    try:
        with open("/proc/net/route") as f:
            next(f)  # header row
            for line in f:
                fields = line.split()
                # Destination 00000000 is the default route (0.0.0.0/0).
                if len(fields) > 1 and fields[1] == "00000000":
                    return fields[0]
    except Exception:
        pass
    return None


def entry_for(name, totals, prev_ifaces, prev_state, elapsed, valid_window):
    rx_total = totals["rx"]
    tx_total = totals["tx"]

    rx_rate = tx_rate = 0
    was = prev_ifaces.get(name)
    if was and valid_window:
        rx_rate = round(max(0, rx_total - was["rx"]) / elapsed)
        tx_rate = round(max(0, tx_total - was["tx"]) / elapsed)

    state = prev_state.get(name, {})
    top_rx = max(state.get("top_rx", 0), rx_rate)
    top_tx = max(state.get("top_tx", 0), tx_rate)

    history = state.get("history", {"rx": [], "tx": []})
    history_rx = (history.get("rx", []) + [rx_rate])[-HISTORY_LEN:]
    history_tx = (history.get("tx", []) + [tx_rate])[-HISTORY_LEN:]

    return {
        "rx_rate": rx_rate, "tx_rate": tx_rate,
        "rx_total": rx_total, "tx_total": tx_total,
        "top_rx": top_rx, "top_tx": top_tx,
        "history": {"rx": history_rx, "tx": history_tx},
    }


def main():
    now = time.time()
    current = read_interfaces()

    try:
        with open(CACHE_FILE) as f:
            previous = json.load(f)
    except Exception:
        previous = {}

    prev_ifaces = previous.get("ifaces", {})
    prev_state = previous.get("state", {})
    elapsed = now - previous.get("at", 0)
    # A stale cache (first run, or a gap over a minute - the machine slept,
    # the window was closed a long time) would divide a huge byte delta by a
    # huge elapsed time and report a plausible-looking average that describes
    # nothing, so treat it the same as no previous sample at all.
    valid_window = bool(previous) and 0 < elapsed <= 60

    by_iface = {
        name: entry_for(name, totals, prev_ifaces, prev_state, elapsed, valid_window)
        for name, totals in current.items()
    }

    total_counts = {
        "rx": sum(c["rx"] for c in current.values()),
        "tx": sum(c["tx"] for c in current.values()),
    }
    prev_total_counts = {
        "rx": sum(c["rx"] for c in prev_ifaces.values()),
        "tx": sum(c["tx"] for c in prev_ifaces.values()),
    } if prev_ifaces else {}
    by_iface[TOTAL_KEY] = entry_for(
        TOTAL_KEY, total_counts, {TOTAL_KEY: prev_total_counts} if prev_total_counts else {},
        prev_state, elapsed, valid_window)

    os.makedirs(CACHE_DIR, exist_ok=True)
    try:
        with open(CACHE_FILE, "w") as f:
            json.dump({
                "at": now,
                "ifaces": current,
                "state": by_iface,
            }, f)
    except Exception:
        pass

    print(json.dumps({
        "interfaces": sorted(current),
        "default": default_interface(),
        "by_iface": by_iface,
    }))


if __name__ == "__main__":
    main()
