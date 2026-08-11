"""What is editable, and how each thing should be rendered.

Two halves, and the split is the whole design:

- **Described** settings (`FIELDS`) — the ones worth a label, a help line and a
  sensible range. Small, hand-written, and the only thing that needs touching
  when a panel gains a setting worth explaining.
- **Inferred** settings — everything else. A control is chosen from the *value's
  type*, so a key nobody has described still gets an editable row. This is what
  keeps the Waybar page from needing a hand-written form per module: add a module
  to `modules.json` and its keys show up here with no code written.

Inference is deliberately conservative. A type it does not recognise (a nested
object, a list of objects) renders read-only rather than guessing at a widget
that might write the wrong shape back into somebody else's config file.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Field:
    key: str
    label: str
    help: str = ""
    kind: str = "auto"          # auto | bool | int | float | text | choice
    choices: list[tuple[str, Any]] = field(default_factory=list)
    minimum: float = 0
    maximum: float = 100
    step: float = 1
    unit: str = ""


def infer_kind(value: Any) -> str:
    """Pick a control from a value's type. Unknown shapes are read-only."""
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "text"
    return "readonly"


# --- our own files -----------------------------------------------------------

NOTIFICATIONS = [
    Field(
        "dnd",
        "Do not disturb",
        "Suppresses the popups. Notifications still land in the panel — that is "
        "what makes it safe to leave on.",
        kind="bool",
    ),
]

CONTROL_CENTER = [
    Field(
        "weather_location",
        "Weather location",
        "A city name, an airport code, \"lat,lon\", or \"~Landmark\". Leave empty "
        "to let wttr.in guess from the IP — which follows the VPN exit when "
        "Tailscale is routing, so it is worth pinning.",
        kind="text",
    ),
    Field(
        "collapsed",
        "Collapsed sections",
        "Which sections come up shut. Set by collapsing them in the panel itself.",
        kind="readonly",
    ),
]

CLAUDE_USAGE = [
    Field(
        "usage_amount_format",
        "Show",
        "Whether the dial reads as consumed or remaining.",
        kind="choice",
        choices=[("Used", "used"), ("Left", "remaining")],
    ),
    Field(
        "reset_time_format",
        "Reset time",
        "Absolute clock time, or how long until the window rolls over.",
        kind="choice",
        choices=[("Absolute", "absolute"), ("Relative", "relative")],
    ),
    Field(
        "refresh_interval_seconds",
        "Refresh interval",
        "How often the dial is redrawn. The upstream figure does not move fast; "
        "polling harder mostly costs battery.",
        kind="int",
        minimum=30,
        maximum=3600,
        step=30,
        unit="s",
    ),
    Field(
        "show_percent",
        "Percentage on the bar",
        "Draw the number next to the dial as well as in the panel.",
        kind="bool",
    ),
]


@dataclass
class Page:
    ident: str
    title: str
    icon: str
    subtitle: str
    filename: str = ""
    fields: list[Field] = field(default_factory=list)
    defaults: dict[str, Any] = field(default_factory=dict)
    kind: str = "json"          # json | waybar | placeholder
    note: str = ""


PAGES: list[Page] = [
    Page(
        "notifications",
        "Notifications",
        "preferences-system-notifications-symbolic",
        "The daemon, do-not-disturb and history",
        filename="notifications.json",
        fields=NOTIFICATIONS,
        defaults={"dnd": False},
        note=(
            "Quickshell owns org.freedesktop.Notifications on this machine; swaync "
            "is masked and killed at login. History lives in the cache directory and "
            "is capped at 50 entries."
        ),
    ),
    Page(
        "control-center",
        "Control Center",
        "preferences-system-symbolic",
        "Sections, metrics and quick actions",
        filename="control-center.json",
        fields=CONTROL_CENTER,
        note=(
            "Section visibility and the quick-action list are still compiled into "
            "the QML. Making them data-driven is the next step for this page."
        ),
    ),
    Page(
        "usage-dial",
        "Usage dial",
        "utilities-system-monitor-symbolic",
        "How the Claude usage dial reads",
        filename="claude-usage.json",
        fields=CLAUDE_USAGE,
        defaults={
            "usage_amount_format": "used",
            "reset_time_format": "absolute",
            "refresh_interval_seconds": 300,
            "show_percent": False,
        },
    ),
    Page(
        "waybar",
        "Waybar",
        "view-list-symbolic",
        "Modules and their settings, read from modules.json",
        kind="waybar",
        note=(
            "This page is generated from ~/.config/waybar/modules.json — every "
            "module and every key, with the control chosen from the value's type. "
            "Adding a module to that file makes it appear here with no code "
            "written. The file belongs to ML4W and has comments in it, so edits "
            "are made as targeted text replacements rather than by rewriting it."
        ),
    ),
    Page(
        "audio",
        "Audio",
        "audio-volume-high-symbolic",
        "Sound panel",
        kind="placeholder",
        note="The audio panel has no settings file yet — everything in it is live device state.",
    ),
    Page(
        "network",
        "Network and Bluetooth",
        "network-wireless-symbolic",
        "Connection panels",
        kind="placeholder",
        note="Both panels are live state only; nothing to configure yet.",
    ),
]
