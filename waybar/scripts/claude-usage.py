#!/usr/bin/env python3
"""Claude Code plan usage, fetched once and cached for whoever wants to draw it.

This script does one job: keep

    ~/.cache/waybar-control-center/claude-usage-state.json

current, holding the two usage windows that matter - the 5-hour block and the
7-day window, which move on completely different time scales - along with their
reset times and, when a fetch fails, the error and the thing you actually have
to do about it.

That file is the contract. The dial itself is drawn by hyprbar's Quickshell
`Canvas`, which reads the state file directly; nothing here renders anything.
Drawing in the shell rather than shipping a PNG means the dial follows the
wallpaper palette, scales with the bar, and redraws without a signal round-trip.

Running the script also prints the state as JSON on stdout, so it is usable from
a terminal or any other consumer, but the file - not stdout - is what readers
are expected to watch.

Usage data comes from the same undocumented OAuth endpoint that `claude`'s own
/usage panel uses, read with the token in ~/.claude/.credentials.json and
refreshed through the stored refresh token when it has expired.
"""

import json
import os
import sys
import tempfile
import time
import urllib.request

HOME = os.path.expanduser("~")
CRED = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(HOME, ".claude")),
                    ".credentials.json")
SETTINGS = os.path.join(HOME, ".config/waybar-control-center/claude-usage.json")
CACHE_DIR = os.path.join(HOME, ".cache/waybar-control-center")
STATE = os.path.join(CACHE_DIR, "claude-usage-state.json")

UA = "claude-code/2.0.0 (external, cli)"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

DEFAULTS = {
    # Mirrors the option set of the COSMIC YapCap applet, which is where the
    # shape of this came from.
    "usage_amount_format": "used",      # used | remaining
    "reset_time_format": "relative",    # relative | absolute
    "refresh_interval_seconds": 300,
    # Not read here any more - the dial lives in hyprbar now - but the settings
    # panel still offers it and writes it through `--set`, and save_settings
    # silently drops keys it does not know about.
    "show_percent": False,              # draw the block % inside the dial
}


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

def load_settings():
    settings = dict(DEFAULTS)
    try:
        with open(SETTINGS) as f:
            settings.update(json.load(f))
    except Exception:
        pass
    return settings


def save_settings(pairs):
    """Apply `--set key=value ...` and persist.

    The settings panel is QML, which would otherwise have to hand-assemble this
    JSON and shell-quote it. Keeping the write here means there is exactly one
    piece of code that knows the file's shape, and it is the one that also
    reads it.
    """
    settings = load_settings()
    for pair in pairs:
        key, _, value = pair.partition("=")
        if key not in DEFAULTS:
            continue
        default = DEFAULTS[key]
        if isinstance(default, bool):
            settings[key] = value.lower() in ("1", "true", "yes")
        elif isinstance(default, int):
            try:
                settings[key] = int(value)
            except ValueError:
                continue
        else:
            settings[key] = value

    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(SETTINGS))
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
    os.replace(tmp, SETTINGS)
    return settings


# --------------------------------------------------------------------------
# usage endpoint
# --------------------------------------------------------------------------

def fetch_usage(token):
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": UA,
        },
    )
    return json.load(urllib.request.urlopen(req, timeout=10))


def refresh_token(creds):
    o = creds["claudeAiOauth"]
    body = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": o["refreshToken"],
        "client_id": OAUTH_CLIENT_ID,
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/oauth/token",
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": UA,
                 "Accept": "application/json"},
    )
    tok = json.load(urllib.request.urlopen(req, timeout=10))
    o["accessToken"] = tok["access_token"]
    if tok.get("refresh_token"):
        o["refreshToken"] = tok["refresh_token"]
    if tok.get("expires_in"):
        o["expiresAt"] = int(time.time() * 1000) + tok["expires_in"] * 1000

    # Written atomically: a truncated credentials file logs you out of the CLI.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CRED))
    with os.fdopen(fd, "w") as f:
        json.dump(creds, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CRED)
    return o["accessToken"]


def get_usage():
    with open(CRED) as f:
        creds = json.load(f)
    token = creds["claudeAiOauth"]["accessToken"]
    try:
        return fetch_usage(token)
    except Exception:
        return fetch_usage(refresh_token(creds))


# --------------------------------------------------------------------------
# state cache
#
# The bar polls this script on a short fixed tick, so honouring a user-set
# refresh interval has to happen here: only actually hit the network when the
# cached reading has aged past it. The file also gives the dial and the popup
# something to read instead of each making its own request.
# --------------------------------------------------------------------------

def read_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return None


def write_state(state):
    os.makedirs(CACHE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CACHE_DIR)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


# --------------------------------------------------------------------------
# errors
# --------------------------------------------------------------------------

def hint(error):
    """Turn the raw failure into the thing you actually have to do about it.

    An empty dial with a stack trace next to it is only marginally better than
    an empty dial, and these three cases cover essentially every failure this
    script has.
    """
    text = str(error)
    if "invalid_grant" in text or "400" in text:
        # Both the access token and the refresh token have expired, which
        # happens after a long enough gap between Claude Code sessions. Nothing
        # here can recover it - the refresh token is the recovery mechanism.
        # `claude` alone just starts a session against the dead credentials and
        # does not re-authenticate; /login is what actually replaces them.
        return "Both tokens have expired. Run `claude /login` in a terminal to sign in again."
    if "429" in text:
        return "Rate limited by the usage endpoint. It will recover on its own."
    if "No such file" in text or "credentials" in text:
        return "~/.claude/.credentials.json is missing. Run `claude /login` in a terminal."
    return "Check ~/.claude/.credentials.json and network access."


def main():
    if "--set" in sys.argv:
        save_settings(sys.argv[sys.argv.index("--set") + 1:])

    settings = load_settings()

    state = read_state()
    force = "--refresh" in sys.argv

    if state is None:
        stale = True
    else:
        age = time.time() - state["fetched_at"]
        # A reading that failed is retried on the next tick rather than being
        # held for the full refresh interval - otherwise one transient 429 or a
        # token refresh mid-session freezes the dial for five minutes. Still
        # backed off to a minute so a persistent failure is not a hot loop
        # against a rate-limited endpoint.
        stale = age >= (60 if state.get("error") else settings["refresh_interval_seconds"])

    if force or stale:
        try:
            data = get_usage()
            five = data.get("five_hour") or {}
            seven = data.get("seven_day") or {}
            state = {
                "fetched_at": time.time(),
                "block_pct": round(five.get("utilization") or 0),
                "week_pct": round(seven.get("utilization") or 0),
                "block_resets_at": five.get("resets_at"),
                "week_resets_at": seven.get("resets_at"),
                "error": None,
                "error_hint": None,
            }
            write_state(state)
        except Exception as exc:
            # Keep serving the last good reading rather than blanking the dial;
            # `error` in the state file is where the failure gets reported.
            state = state or {"fetched_at": time.time(), "block_pct": 0,
                              "week_pct": 0, "block_resets_at": None,
                              "week_resets_at": None}
            state["error"] = str(exc)
            # Stored alongside the raw error so every reader - dial and panel
            # alike - shows the same actionable line without duplicating the
            # mapping.
            state["error_hint"] = hint(exc)
            write_state(state)

    # The state file is the contract; stdout is a convenience for shells and
    # any consumer that would rather pipe than read the cache path.
    print(json.dumps(state))


if __name__ == "__main__":
    main()
