"""Reading and writing the JSON the panels already own.

The settings app deliberately holds no state of its own. Each panel keeps owning
its settings file and watches it through a Quickshell `FileView`, so writing the
file *is* applying the setting — there is no IPC, no daemon, and nothing in the
running shell has to know this app exists. If this app is never launched,
everything keeps working exactly as it does now.

Two flavours of file, and the difference matters:

- **Ours** (`~/.config/hyprbar/*.json`) — strict JSON, written by
  this project, safe to re-serialise wholesale.
- **Waybar's** (`~/.config/waybar/modules.json`) — JSONC: `//` comments and
  trailing commas, and owned by ML4W. Re-serialising it would silently delete
  every comment in it, so it is parsed leniently and edited *surgically*. See
  `JsoncFile`.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

CONFIG_DIR = Path(
    os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")
) / "hyprbar"

CACHE_DIR = Path(
    os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")
) / "hyprbar"

WAYBAR_DIR = Path(
    os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")
) / "waybar"


def _atomic_write(path: Path, text: str) -> None:
    """Write via a temp file in the same directory, then rename.

    A panel is watching this file. A partial write is a parse error on the other
    side, and Quickshell's FileView reacts to it by falling back to defaults —
    i.e. a half-written file looks exactly like "the user reset everything".
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class JsonFile:
    """One of our own strict-JSON settings files."""

    def __init__(self, path: Path, defaults: dict[str, Any] | None = None):
        self.path = path
        self.defaults = dict(defaults or {})
        self.data: dict[str, Any] = {}
        self.load()

    def load(self) -> None:
        # A missing file is the normal first-run case, not an error — the panel
        # treats it the same way.
        try:
            self.data = json.loads(self.path.read_text())
        except (OSError, json.JSONDecodeError):
            self.data = {}
        merged = dict(self.defaults)
        merged.update(self.data)
        self.data = merged

    def get(self, key: str, fallback: Any = None) -> Any:
        return self.data.get(key, fallback)

    def set(self, key: str, value: Any) -> None:
        if self.data.get(key) == value:
            return
        self.data[key] = value
        self.save()

    def save(self) -> None:
        _atomic_write(self.path, json.dumps(self.data, indent=2) + "\n")


_TRAILING_COMMA_RE = re.compile(r",(\s*[}\]])")


def strip_comments(text: str) -> str:
    """Remove `//` and `/* */` comments that are not inside a string literal.

    Deliberately a scanner and not a regex. The regex version of this looked
    fine and silently parsed *nothing*, because real comments in this file
    contain quotes and colons:

        // "scroll-step": 1, // %, can be a float

    Any pattern cheap enough to write in one line either stops at the quote or
    eats into the next string. Tracking string state is the only version that
    is actually correct, and it is barely longer.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


class JsoncFile:
    """Waybar's `modules.json`: JSON with comments, owned by somebody else.

    Parsed leniently for display. **Never re-serialised** — edits are done as
    targeted text replacements on the original bytes so ML4W's comments, their
    ordering, and their deliberately commented-out modules all survive.
    """

    def __init__(self, path: Path):
        self.path = path
        self.text = ""
        self.data: dict[str, Any] = {}
        self.load()

    def load(self) -> None:
        try:
            self.text = self.path.read_text()
        except OSError:
            self.text = ""
            self.data = {}
            return
        self.data = self._parse(self.text)

    @staticmethod
    def _parse(text: str) -> dict[str, Any]:
        stripped = strip_comments(text)
        stripped = _TRAILING_COMMA_RE.sub(r"\1", stripped)
        try:
            return json.loads(stripped)
        except json.JSONDecodeError:
            return {}

    def module_names(self) -> list[str]:
        return sorted(self.data.keys())

    def set_scalar(self, module: str, key: str, value: Any) -> bool:
        """Replace one `"key": <scalar>` inside one module block, in place.

        Returns False when the key could not be located unambiguously, which is
        the safe outcome: refusing to write beats rewriting the wrong line in a
        file this project does not own.
        """
        start = self._module_span(module)
        if start is None:
            return False
        begin, end = start
        block = self.text[begin:end]

        pattern = re.compile(
            r'(^\s*"' + re.escape(key) + r'"\s*:\s*)([^,\n]*)(,?\s*$)',
            re.MULTILINE,
        )
        matches = list(pattern.finditer(block))
        if len(matches) != 1:
            return False

        m = matches[0]
        new_block = block[: m.start()] + m.group(1) + json.dumps(value) + m.group(3) + block[m.end():]
        self.text = self.text[:begin] + new_block + self.text[end:]
        _atomic_write(self.path, self.text)
        self.load()
        return True

    def _module_span(self, module: str) -> tuple[int, int] | None:
        """Byte span of one `"module": { ... }` block, brace-matched."""
        key = f'"{module}"'
        idx = self.text.find(key)
        if idx < 0:
            return None
        brace = self.text.find("{", idx)
        if brace < 0:
            return None
        depth = 0
        in_string = False
        escape = False
        for i in range(brace, len(self.text)):
            ch = self.text[i]
            if escape:
                escape = False
                continue
            if ch == "\\":
                escape = True
                continue
            if ch == '"':
                in_string = not in_string
                continue
            if in_string:
                continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return (brace, i + 1)
        return None
