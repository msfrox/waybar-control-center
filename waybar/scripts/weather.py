#!/usr/bin/env python3
"""Weather for the Control Center's weather section.

    weather.py            -> cached JSON, refetching only if the cache is stale
    weather.py --refresh  -> force a fetch

The bar module this replaces was `curl -s 'wttr.in/?format=%c+%t'` on a 1800s
interval — one glyph and a temperature, and nothing to click. The panel has room for
the condition text, feels-like, humidity, wind and a three-day outlook, so this asks
wttr.in for its JSON form (`?format=j1`) instead and reshapes it.

Two things wttr.in does that have to be handled here:

**It is slow and rate-limited.** A cold request routinely takes several seconds, and
hammering it earns a 503. So the result is cached on disk and only refetched once it
is older than TTL. The Control Center calls this every time it opens; almost all of
those calls are served from the cache without touching the network.

**Location is geo-IP by default**, which is coarse — it resolves to whichever exchange
the ISP hands out, and lands on the VPN exit entirely whenever Tailscale is routing. To
pin it, set `weather_location` in ~/.config/hyprbar/control-center.json;
that is the file the panel already owns, so the Settings app can edit it and there is
nothing to restart. WEATHER_LOCATION in the environment overrides the file, and
DEFAULT_LOCATION below is the last fallback. wttr.in takes a city name ("Colombo"),
an airport code ("CMB"), "~Some+Place" for a landmark, or a raw "6.9271,79.8612".

Output is always a JSON object. On failure it carries an "error" key and, if there is
one, the last good reading alongside it, so the panel can show stale data with a note
rather than going blank.
"""

import json
import os
import subprocess
import sys
import time
import urllib.parse

CACHE_DIR = os.path.expanduser("~/.cache/hyprbar")
CACHE = os.path.join(CACHE_DIR, "weather.json")
SETTINGS = os.path.expanduser(
    "~/.config/hyprbar/control-center.json")
TTL = 1800  # seconds; matches the old bar module's interval
DEFAULT_LOCATION = ""  # "" = wttr.in geo-IP guess


def configured_location():
    try:
        with open(SETTINGS) as f:
            value = json.load(f).get("weather_location", "")
        if isinstance(value, str) and value.strip():
            return value.strip()
    except Exception:
        pass
    return DEFAULT_LOCATION


LOCATION = os.environ.get("WEATHER_LOCATION") or configured_location()

# wttr.in's own condition codes -> icon ligature names.
#
# EVERY name here is verified present in MaterialIconsRound-Regular.otf, which is the
# only Material family installed. The obvious modern names -- rainy, clear_day,
# partly_cloudy_day, foggy, weather_snowy, snowing_heavy -- belong to *Material
# Symbols*, a different font that is NOT installed, and a missing ligature renders as
# nothing at all rather than as a fallback box, so the chip silently loses its icon
# while the temperature still shows. Check before adding one:
#
#   python -c "from fontTools.ttLib import TTFont; print('grain' in \
#     TTFont('/usr/share/fonts/Material-Icons/MaterialIconsRound-Regular.otf').getGlyphOrder())"
#
# The classic set has no dedicated rain glyph, so wetness is graded by intensity:
# grain (drizzle/light) -> water_drop (moderate) -> umbrella (heavy). Anything frozen
# collapses to ac_unit; there is no separate sleet or hail glyph to split them with.
ICONS = {
    "113": "wb_sunny",      # clear / sunny
    "116": "wb_cloudy",     # partly cloudy
    "119": "cloud",         # cloudy
    "122": "cloud",         # overcast
    "143": "blur_on",       # mist
    "176": "grain",         # patchy rain nearby
    "179": "ac_unit",       # patchy snow
    "182": "ac_unit",       # patchy sleet
    "185": "ac_unit",       # patchy freezing drizzle
    "200": "thunderstorm",  # thundery outbreaks
    "227": "ac_unit",       # blowing snow
    "230": "ac_unit",       # blizzard
    "248": "blur_on",       # fog
    "260": "blur_on",       # freezing fog
    "263": "grain",         # patchy light drizzle
    "266": "grain",         # light drizzle
    "281": "ac_unit",       # freezing drizzle
    "284": "ac_unit",       # heavy freezing drizzle
    "293": "grain",         # patchy light rain
    "296": "grain",         # light rain
    "299": "water_drop",    # moderate rain at times
    "302": "water_drop",    # moderate rain
    "305": "umbrella",      # heavy rain at times
    "308": "umbrella",      # heavy rain
    "311": "ac_unit",       # light freezing rain
    "314": "ac_unit",       # moderate/heavy freezing rain
    "317": "ac_unit",       # light sleet
    "320": "ac_unit",       # moderate/heavy sleet
    "323": "ac_unit",       # patchy light snow
    "326": "ac_unit",       # light snow
    "329": "ac_unit",       # patchy moderate snow
    "332": "ac_unit",       # moderate snow
    "335": "ac_unit",       # patchy heavy snow
    "338": "ac_unit",       # heavy snow
    "350": "ac_unit",       # ice pellets
    "353": "grain",         # light rain shower
    "356": "water_drop",    # moderate/heavy rain shower
    "359": "umbrella",      # torrential rain shower
    "362": "ac_unit",       # light sleet showers
    "365": "ac_unit",       # moderate/heavy sleet showers
    "368": "ac_unit",       # light snow showers
    "371": "ac_unit",       # moderate/heavy snow showers
    "374": "ac_unit",       # light showers of ice pellets
    "377": "ac_unit",       # moderate/heavy ice pellets
    "386": "thunderstorm",  # patchy light rain with thunder
    "389": "thunderstorm",  # moderate/heavy rain with thunder
    "392": "thunderstorm",  # patchy light snow with thunder
    "395": "thunderstorm",  # moderate/heavy snow with thunder
}


def read_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except Exception:
        return None


def write_cache(payload):
    os.makedirs(CACHE_DIR, exist_ok=True)
    try:
        with open(CACHE, "w") as f:
            json.dump(payload, f)
    except Exception:
        pass


def fetch():
    # quote(): a location is free text out of a config file - "New York" or
    # "~Sigiriya Rock" have to survive as one path segment. safe="~," keeps the
    # landmark prefix and the lat,lon form intact rather than percent-encoding them.
    url = "https://wttr.in/%s?format=j1" % urllib.parse.quote(LOCATION, safe="~,")
    # curl rather than urllib: it already honours the proxy env and gives a clean
    # timeout, and it is what the old bar module used.
    out = subprocess.run(
        ["curl", "-sf", "--max-time", "15", url],
        capture_output=True, text=True, timeout=20,
    )
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError("wttr.in request failed (curl exit %d)" % out.returncode)
    return json.loads(out.stdout)


def shape(raw):
    current = raw["current_condition"][0]
    area = (raw.get("nearest_area") or [{}])[0]

    def field(node, key):
        entries = node.get(key) or []
        return entries[0].get("value", "") if entries else ""

    place = ", ".join(x for x in (
        field(area, "areaName"), field(area, "country")) if x)

    code = current.get("weatherCode", "")
    days = []
    for day in (raw.get("weather") or [])[:3]:
        hourly = day.get("hourly") or []
        # Midday is the representative slot: index 4 is 1200 in wttr.in's 3-hourly
        # series. Falling back to the middle of whatever is there keeps this safe
        # if the series is ever short.
        noon = hourly[4] if len(hourly) > 4 else (
            hourly[len(hourly) // 2] if hourly else {})
        days.append({
            "date": day.get("date", ""),
            "max": day.get("maxtempC", ""),
            "min": day.get("mintempC", ""),
            "icon": ICONS.get(noon.get("weatherCode", ""), "cloud"),
            "desc": field(noon, "weatherDesc"),
        })

    return {
        "location": place,
        "temp": current.get("temp_C", ""),
        "feels": current.get("FeelsLikeC", ""),
        "desc": field(current, "weatherDesc"),
        "icon": ICONS.get(code, "cloud"),
        "humidity": current.get("humidity", ""),
        "wind": current.get("windspeedKmph", ""),
        "wind_dir": current.get("winddir16Point", ""),
        "uv": current.get("uvIndex", ""),
        "observed": current.get("localObsDateTime", ""),
        "days": days,
        "fetched": int(time.time()),
        # What was asked for, not what wttr.in resolved it to. Changing the setting
        # has to invalidate the cache, and comparing against the resolved "location"
        # would not do that - "Colombo" comes back as "Colombo, Sri Lanka".
        "queried": LOCATION,
    }


if __name__ == "__main__":
    force = "--refresh" in sys.argv
    cached = read_cache()

    fresh_enough = (
        cached
        and not force
        and not cached.get("error")
        and cached.get("queried", "") == LOCATION
        and (time.time() - cached.get("fetched", 0)) < TTL
    )
    if fresh_enough:
        print(json.dumps(cached))
        raise SystemExit(0)

    try:
        payload = shape(fetch())
        write_cache(payload)
        print(json.dumps(payload))
    except Exception as exc:
        # Keep serving the last good reading rather than blanking the section;
        # the panel shows it greyed with the error as a tooltip.
        stale = cached or {}
        stale = {k: v for k, v in stale.items() if k != "error"}
        stale["error"] = str(exc)
        print(json.dumps(stale))
