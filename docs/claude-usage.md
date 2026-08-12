# Claude usage dial

A two-window usage indicator for the bar, plus a panel carrying the display options.

```
outer ring   7-day window, swept clockwise from 12 o'clock
inner pie    current 5-hour block, quantised to 10% steps
```

## Why two windows

The original badge was one quarter-filled circle glyph (`○◔◑◕●`) showing whichever of the
two usage windows happened to be higher. That is close to the least useful summary of
them: the 5-hour block and the 7-day window move on completely different time scales, and
the *smaller* one is frequently the one about to matter. A dial can carry both, and give
each its own colour level rather than letting one class colour the whole module.

## How it fits together

```
claude-usage.py  →  claude-usage-state.json  →  hyprbar's Quickshell Canvas
   (fetch)              (the contract)                  (draws the dial)
```

The script is a pure data source: it talks to the usage endpoint, caches the reading, and
prints the same JSON on stdout so it is usable from a shell. It draws nothing. The dial is
drawn natively by a `Canvas` in **hyprbar** that reads the state file — so it follows the wallpaper palette, scales with the bar, and redraws without a signal
round-trip or a PNG on disk.

The 5-hour fill is rounded to 10% in the dial on purpose. The dial is a glanceable
indicator and a continuously creeping wedge reads as noise; the exact figure is one click
away in the panel.

## Files

| Path | Role |
|---|---|
| `waybar/scripts/claude-usage.py` | fetch, cache, settings |
| `~/.cache/waybar-control-center/claude-usage-state.json` | last good reading — **the contract** |
| `~/.config/waybar-control-center/claude-usage.json` | settings |

The script owns all three. The Quickshell panel reads the state file and writes settings
through `claude-usage.py --set key=value` — two processes hand-editing the same JSON would
be a race for no benefit.

The state file's keys are read by another repo, so they are fixed: `fetched_at`,
`block_pct`, `week_pct`, `block_resets_at`, `week_resets_at`, `error`, `error_hint`.

## Refresh

The bar polls the script on a short fixed tick (60s), so honouring a user-set refresh
interval has to happen inside the script: it only hits the network once the cached reading
has aged past the configured interval. A reading that **failed** is retried after 60s
rather than held for the full interval — otherwise one transient 429, or a token refresh
landing mid-session, freezes the dial for five minutes.

`--refresh` forces a fetch regardless of age; the panel's refresh button uses it. Because
the dial watches the state file, rewriting that file is all the notification the bar needs.

## Panel options

A port of the option set the COSMIC [YapCap](https://github.com/TopiCsarno/YapCap) applet
exposes, which is where the idea came from:

| Option | Values |
|---|---|
| Show | Used · Remaining |
| Reset times | Relative · Absolute |
| Refresh every | 1m · 5m · 10m · 30m |
| Dial label | None · Session % |

`show_percent` (Dial label) is written to the settings file but no longer read by the
script — honouring it is now the drawing side's job, i.e. hyprbar's.

Plus a refresh action and a link to the full `ccusage weekly --breakdown`.

The usage bars in the panel always fill in the **used** direction whichever way the number
is phrased — a bar that empties as you consume quota reads backwards.

## Where the numbers come from

`https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint `claude`'s own
`/usage` panel uses — authenticated with the token in `~/.claude/.credentials.json`, and
refreshed through the stored refresh token when the access token has expired.

> [!warning] The failure mode this design exists to avoid
> An earlier version read a cache file written by a statusline plugin. That cache only
> updated when the plugin's statusline command fired, which never happens in headless
> sessions — so the badge showed valid-looking, permanently stale numbers with no error.
> Nothing here depends on any other process having run.

Failures are reported with the fix rather than a status code:

| Failure | What it means |
|---|---|
| `invalid_grant` / 400 | Both tokens have expired. Run `claude` in a terminal once to log in again — the refresh token *is* the recovery mechanism, so retrying cannot help. |
| 429 | Rate limited by the endpoint. Recovers on its own. |
| missing credentials | Log in with `claude` once. |

`error_hint` is stored in the state file alongside the raw `error`, so every reader — the
dial and the panel — shows the same actionable line without duplicating the mapping.

## Bar height

The old text badge had the tallest label on the bar, and a bar is measured from its
tallest child — so that module's `font-size` silently set the whole bar's height, and
Hyprland's reserved area with it. A fixed-size dial has no such coupling. Check with:

```bash
hyprctl monitors -j | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['reserved'])"
```
