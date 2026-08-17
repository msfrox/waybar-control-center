"""The window: a sidebar of pages, a preference pane per page.

Standalone on purpose. This is not a Quickshell window and does not talk to the
running shell — it edits files, and the panels pick the change up through the
`FileView` watch they already have. That means it costs nothing when it is not
open, which matters because the shell it configures is running all day and this
is looked at once a month.

It is also where the rest of the session's controls are expected to land later,
which is the other reason it is its own process rather than a seventh panel.
"""

from __future__ import annotations

from typing import Any

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from . import schema  # noqa: E402
from .rows import build_row, humanise  # noqa: E402
from .store import CONFIG_DIR, WAYBAR_DIR, JsonFile, JsoncFile  # noqa: E402


class SettingsWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application, start_page: str = ""):
        super().__init__(application=app, title="Control Center Settings")
        self.set_default_size(980, 720)

        self._toasts = Adw.ToastOverlay()
        split = Adw.NavigationSplitView()
        self._toasts.set_child(split)
        self.set_content(self._toasts)

        # --- sidebar ---
        self._list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self._list.add_css_class("navigation-sidebar")
        for page in schema.PAGES:
            row = Adw.ActionRow(title=page.title, subtitle=page.subtitle)
            icon = Gtk.Image.new_from_icon_name(page.icon)
            row.add_prefix(icon)
            row.set_activatable(True)
            self._list.append(row)
        self._list.connect("row-selected", self._on_page_selected)

        sidebar_scroll = Gtk.ScrolledWindow(child=self._list, vexpand=True)
        sidebar = Adw.NavigationPage(
            title="Settings",
            child=Adw.ToolbarView(content=sidebar_scroll),
        )
        sidebar.get_child().add_top_bar(Adw.HeaderBar())
        split.set_sidebar(sidebar)

        # --- content ---
        self._content_holder = Adw.ToolbarView()
        self._content_holder.add_top_bar(Adw.HeaderBar())
        self._content_page = Adw.NavigationPage(
            title="Notifications", child=self._content_holder
        )
        split.set_content(self._content_page)

        index = next(
            (i for i, p in enumerate(schema.PAGES) if p.ident == start_page), 0
        )
        self._list.select_row(self._list.get_row_at_index(index))

    # ------------------------------------------------------------------ pages

    def _on_page_selected(self, _listbox: Gtk.ListBox, row: Gtk.ListBoxRow | None) -> None:
        if row is None:
            return
        page = schema.PAGES[row.get_index()]
        self._content_page.set_title(page.title)
        self._content_holder.set_content(self._build_page(page))

    def _build_page(self, page: schema.Page) -> Gtk.Widget:
        prefs = Adw.PreferencesPage()

        if page.kind == "waybar":
            self._fill_waybar(prefs, page)
        elif page.kind == "placeholder":
            self._fill_note_only(prefs, page)
        else:
            self._fill_json(prefs, page)

        return prefs

    def _fill_note_only(self, prefs: Adw.PreferencesPage, page: schema.Page) -> None:
        group = Adw.PreferencesGroup(title=page.title, description=page.note)
        prefs.add(group)

    def _fill_json(self, prefs: Adw.PreferencesPage, page: schema.Page) -> None:
        store = JsonFile(CONFIG_DIR / page.filename, page.defaults)
        described = {f.key: f for f in page.fields}

        def on_change(key: str, value: Any) -> None:
            store.set(key, value)
            self._toast(f"Saved {humanise(key).lower()}")

        group = Adw.PreferencesGroup(
            title=page.title,
            description=page.note or f"Written to ~/.config/hyprbar/{page.filename}",
        )
        prefs.add(group)

        # Described fields first and in their declared order — that order is
        # editorial, not alphabetical, and it is the whole reason they are
        # described rather than inferred.
        seen: set[str] = set()
        for spec in page.fields:
            value = store.get(spec.key, page.defaults.get(spec.key))
            if value is None and spec.key not in store.data:
                continue
            group.add(build_row(spec.key, value, spec, on_change))
            seen.add(spec.key)

        extras = [k for k in sorted(store.data) if k not in seen]
        if extras:
            extra_group = Adw.PreferencesGroup(
                title="Other keys",
                description=(
                    "Present in the file but not described in this app. Controls "
                    "are chosen from each value's type."
                ),
            )
            prefs.add(extra_group)
            for key in extras:
                extra_group.add(
                    build_row(key, store.data[key], described.get(key), on_change)
                )

    def _fill_waybar(self, prefs: Adw.PreferencesPage, page: schema.Page) -> None:
        modules = JsoncFile(WAYBAR_DIR / "modules.json")

        intro = Adw.PreferencesGroup(title="Waybar modules", description=page.note)
        prefs.add(intro)

        if not modules.data:
            intro.add(
                Adw.ActionRow(
                    title="modules.json could not be read",
                    subtitle=str(WAYBAR_DIR / "modules.json"),
                )
            )
            return

        for name in modules.module_names():
            body = modules.data.get(name)
            if not isinstance(body, dict):
                continue

            group = Adw.PreferencesGroup(title=name)
            prefs.add(group)

            def make_handler(module_name: str):
                def handler(key: str, value: Any) -> None:
                    if modules.set_scalar(module_name, key, value):
                        self._toast(f"{module_name}: {key} saved — reload Waybar to apply")
                    else:
                        # Refusing to write beats rewriting the wrong line in a
                        # file this project does not own.
                        self._toast(
                            f"Could not safely locate {key} in {module_name} — left unchanged"
                        )
                return handler

            handler = make_handler(name)
            for key in sorted(body):
                group.add(build_row(key, body[key], None, handler))

    # ------------------------------------------------------------------ misc

    def _toast(self, message: str) -> None:
        self._toasts.add_toast(Adw.Toast(title=message, timeout=2))


class SettingsApp(Adw.Application):
    def __init__(self, start_page: str = "") -> None:
        super().__init__(
            application_id="lk.gear.WaybarControlCenterSettings",
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )
        self._start_page = start_page

    def do_activate(self) -> None:  # noqa: N802  (GObject naming)
        # Follow the desktop rather than GtkSettings' legacy dark-theme flag,
        # which libadwaita warns about and ignores.
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.PREFER_DARK)
        window = self.props.active_window or SettingsWindow(self, self._start_page)
        window.present()


def main(argv: list[str] | None = None) -> int:
    """`--page <ident>` opens straight onto one page.

    Gio would swallow an unknown argument, so the flag is pulled out before the
    application ever sees argv. It exists so the Control Center can deep-link to
    the page for the thing you just right-clicked.
    """
    argv = list(argv or [])
    start = ""
    if "--page" in argv:
        i = argv.index("--page")
        if i + 1 < len(argv):
            start = argv[i + 1]
            del argv[i:i + 2]
    GLib.set_application_name("Control Center Settings")
    return SettingsApp(start).run(argv)
