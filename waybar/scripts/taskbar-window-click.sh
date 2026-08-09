#!/usr/bin/env bash
# Click handler for the workspace taskbar (hyprland/workspaces -> workspace-taskbar).
#
# Waybar's workspace-taskbar has a single `on-click-window` hook for every button,
# handing us {address} and {button}, so the left/middle split that wlr/taskbar got
# for free from `on-click` / `on-click-middle` has to be demultiplexed here.
#
#   left (1)   -> focus the window
#   middle (2) -> close it
#   right (3)  -> ignored, so a stray right-click never kills a window
#
# Hyprland 0.56 parses every dispatch payload as Lua, so the legacy
# `dispatch focuswindow address:0x...` form errors out ("')' expected near ...").
# The Lua dispatchers are `hl.dsp.focus{window=...}` and `hl.dsp.window.close{window=...}`
# -- note `focuswindow` and `killactive` do not exist as Lua fields at all.
set -euo pipefail

addr="${1:-}"
button="${2:-1}"

[ -n "$addr" ] || exit 0

case "$button" in
  1) hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null ;;
  2) hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null ;;
  *) ;;
esac
