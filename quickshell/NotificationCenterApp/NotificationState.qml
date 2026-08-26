pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

// The notification daemon.
//
// Only one process on the bus can own org.freedesktop.Notifications, so taking
// this over means swaync has to go — see ~/.config/hypr/shehan/notifications.lua
// for the kill, and docs/notifications.md for why.
//
// Everything notification-shaped hangs off this one singleton: the panel reads
// `list`, the toasts read `toasts`, the Control Center reads `count` and `dnd`.
// It is a singleton rather than state inside the panel because the toasts have
// to keep firing while the panel is closed and unmapped.
Singleton {
    id: root

    // --- STORE ---------------------------------------------------------------
    // The server owns the objects; `trackedNotifications` is its live model and
    // the only thing keeping a Notification alive. Reversed here because the
    // server appends and the panel wants newest first.
    readonly property list<var> live: [...server.trackedNotifications.values].reverse()

    // Notifications from before the last restart, read back from disk. These are
    // PLAIN OBJECTS, not Notification instances: a NotificationServer has no way
    // to re-inject one, so history can only ever be a snapshot. They carry the
    // same property names so NotificationEntry renders both without branching,
    // plus `historic: true` so the few places that DO have to branch can.
    //
    // What a historic entry cannot do is invoke an action — the sending app is
    // long gone and the id is stale — so they are saved with `actions: []`.
    property list<var> history: []

    readonly property list<var> list: [...root.live, ...root.history]
    readonly property int count: root.live.length + root.history.length

    // Notifications currently showing as a toast. Separate from `list`: a toast
    // disappearing must not clear the panel entry, and a panel entry dismissed
    // by hand must take its toast with it.
    property list<var> toasts: []

    // Arrival times, keyed by notification id. A Notification carries no
    // timestamp of its own, so the "5m ago" line has to be recorded here as
    // they land. Entries are dropped in dropStale() when their notification goes.
    property var arrivals: ({})

    // Ticks the relative timestamps in the panel. One timer for the whole list
    // rather than one per row.
    property int clockTick: 0

    function ageTextFor(n: var): string {
        root.clockTick // re-evaluate on every tick
        // NotificationEntry.qml binds `text: ageTextFor(entry.notification)`.
        // When an entry is dismissed the delegate tears down, `entry.notification`
        // goes null, and the binding re-evaluates ONCE MORE before the delegate is
        // destroyed -- so `n` arrives null and the dereference below threw. One
        // throw per dismissal: 228 of them in a 685-line autostart.log, a third of
        // everything that file recorded, which buried every other message in it.
        // Returning "" is correct rather than merely defensive -- the delegate is
        // on its way out and the value is discarded. Fixed 2026-08-20, Phase 2.0.
        if (!n) return ""
        // A historic entry carries its own timestamp; a live one is looked up in
        // `arrivals`, because a Notification has no timestamp of its own.
        const at = n.historic ? n.at : root.arrivals[n.id]
        if (at === undefined) return ""
        const secs = Math.floor((Date.now() - at) / 1000)
        if (secs < 60) return "now"
        if (secs < 3600) return Math.floor(secs / 60) + "m ago"
        if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
        return Math.floor(secs / 86400) + "d ago"
    }

    // --- DO NOT DISTURB ------------------------------------------------------
    // DND suppresses the toast, it does not drop the notification — the panel
    // still fills up, which is the behaviour swaync had and the one that makes
    // DND safe to leave on.
    property bool dnd: false

    function toggleDnd(): void {
        root.dnd = !root.dnd
        if (root.dnd) root.toasts = []
        settings.dnd = root.dnd
        settingsFile.writeAdapter()
    }

    // --- ACTIONS -------------------------------------------------------------
    function clearAll(): void {
        // dismiss() mutates trackedNotifications, so iterate over a copy.
        for (const n of [...server.trackedNotifications.values]) n.dismiss()
        root.toasts = []
        root.history = []
        root.persist()
    }

    function dismiss(n: var): void {
        if (n.historic) {
            // Nothing to tell the bus about — just forget it.
            root.history = root.history.filter(h => h.at !== n.at || h.summary !== n.summary)
            root.persist()
            return
        }
        root.dropToast(n)
        n.dismiss()
    }

    function togglePanel(): void {
        Quickshell.execDetached(["qs", "ipc", "call", "notifications", "toggle"])
    }

    // --- TOASTS --------------------------------------------------------------
    // Timeouts default to the values that were in ~/.config/swaync/config.json
    // (2s low, 4s normal, 6s critical) but are editable from hyprsys' Notifications
    // page now -- see `settings` below, read from the same settingsFile as `dnd`.
    // A notification that asks for its own timeout still gets it; 0 means "until
    // dismissed", same meaning as setting a tier's own timeout to 0.
    function timeoutFor(n: var): int {
        if (n.expireTimeout > 0) return n.expireTimeout
        if (n.expireTimeout === 0) return 0
        if (n.urgency === NotificationUrgency.Critical) return root.timeoutCritical
        if (n.urgency === NotificationUrgency.Low) return root.timeoutLow
        return root.timeoutNormal
    }

    property int timeoutCritical: 6000
    property int timeoutNormal: 4000
    property int timeoutLow: 2000

    function dropToast(n: var): void {
        root.toasts = root.toasts.filter(t => t !== n)
        // A transient notification is an OSD, not a message — it was only ever
        // meant to be the popup, so it leaves the panel with its toast.
        if (n.transient && n.tracked) n.dismiss()
    }

    NotificationServer {
        id: server

        // Survive a QML hot-reload without dropping what is already on screen.
        keepOnReload: true

        actionsSupported: true
        actionIconsSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        imageSupported: true
        inlineReplySupported: true
        persistenceSupported: true

        onNotification: (notification) => {
            // Nothing keeps a Notification alive unless it is tracked — an
            // untracked one is destroyed the moment this handler returns, and
            // any reference kept to it dangles. So track everything, including
            // transients, and let dropToast() clear those again.
            notification.tracked = true
            root.arrivals[notification.id] = Date.now()

            // A notification can close for reasons this shell never asked for
            // - the sending app withdrawing or replacing it over
            // CloseNotification is common (zapzap does it on every new
            // message). The server destroys the underlying object right
            // after emitting this, and `toasts` is a plain array kept by
            // hand, so without this a toast for a notification closed that
            // way is left holding a dangling reference: every read of it
            // throws, dismiss() throws before it reaches dropToast(), and
            // the toast is stuck on screen until clearAll() wipes the array
            // wholesale instead of reading through it.
            notification.closed.connect(() => root.dropToast(notification))

            if (root.dnd) {
                if (notification.transient) notification.dismiss()
                return
            }
            root.toasts = [...root.toasts, notification]
        }
    }

    // --- HISTORY ACROSS RESTARTS ---------------------------------------------
    // Kept in $XDG_CACHE, not $XDG_CONFIG: it is regenerable state, and losing it
    // costs nothing. Capped, because an uncapped list is a slow leak that only
    // shows up months later as a slow panel.
    readonly property int historyLimit: 50

    // Guard against the startup race: `live` changes as the server comes up,
    // which fires the debounce, and a persist() that runs before the file has
    // been read would write an empty array over the real history.
    property bool historyLoaded: false

    function snapshotOf(n: var): var {
        return {
            historic: true,
            at: root.arrivals[n.id] !== undefined ? root.arrivals[n.id] : Date.now(),
            appName: n.appName,
            appIcon: n.appIcon,
            summary: n.summary,
            body: n.body,
            urgency: n.urgency,
            image: n.image,
            // Deliberately empty — see the `history` comment above.
            actions: []
        }
    }

    function persist(): void {
        if (!root.historyLoaded) return

        // Live notifications are snapshotted too. If the shell dies without
        // warning, whatever was on screen is what should come back.
        const snapshot = [
            ...root.live.filter(n => !n.transient).map(n => root.snapshotOf(n)),
            ...root.history
        ].slice(0, root.historyLimit)

        historyFile.setText(JSON.stringify(snapshot))
    }

    // Debounced: a burst of notifications would otherwise rewrite the file once
    // per notification, and `live` also churns on every dismiss.
    Timer {
        id: persistDebounce
        interval: 1500
        repeat: false
        onTriggered: root.persist()
    }

    onLiveChanged: persistDebounce.restart()

    FileView {
        id: historyFile
        path: Quickshell.env("HOME") + "/.cache/hyprbar/notification-history.json"
        // Write to a temp file and rename, so a poweroff mid-write leaves the
        // previous history intact rather than a truncated file.
        atomicWrites: true
        // No watchChanges: this file has exactly one writer, and watching it would
        // feed every write straight back in as a load.
        onLoaded: {
            try {
                const parsed = JSON.parse(historyFile.text())
                root.history = Array.isArray(parsed) ? parsed : []
            } catch (e) {
                // A truncated write from a hard poweroff is not worth a crash.
                root.history = []
            }
            root.historyLoaded = true
        }
        // No file yet is the normal first-run case, not an error.
        onLoadFailed: (error) => {
            root.history = []
            root.historyLoaded = true
        }
    }

    // --- TOAST STYLE (position/animation/font) --------------------------------
    // Configured on hyprsys' Notifications page, under the unprefixed
    // position/animation/font keys — hyprbar's OSD toast primitive
    // (OsdWindow.qml) has its OWN independent position/animation/font/timeout
    // under a `toast*` prefix in the SAME file; the two surfaces are
    // deliberately not aliases of each other. Defaults here match
    // NotificationToasts.qml's ORIGINAL hardcoded look exactly: bottom-right,
    // slide-in-from-the-right, no font override — so an install with no
    // notifications.json yet looks exactly as it always has.
    property string position: "bottom-right"
    property string animation: "slide"
    property string font: ""

    // --- PERSISTENCE ---------------------------------------------------------
    // DND lives here, in $XDG_CONFIG, because it is a preference. The
    // notification list is persisted too but separately, in $XDG_CACHE — see the
    // HISTORY block above. Keeping them in one file would put regenerable state
    // into a file the settings app treats as user intent.
    FileView {
        id: settingsFile
        path: Quickshell.env("HOME") + "/.config/hyprbar/notifications.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.dnd = settings.dnd
            root.timeoutCritical = settings.timeoutCritical
            root.timeoutNormal = settings.timeoutNormal
            root.timeoutLow = settings.timeoutLow
            root.position = settings.position
            root.animation = settings.animation
            root.font = settings.font
        }

        // No settings file yet is the normal first-run case, not an error.
        onLoadFailed: (error) => {
            root.dnd = false
            root.timeoutCritical = 6000
            root.timeoutNormal = 4000
            root.timeoutLow = 2000
            root.position = "bottom-right"
            root.animation = "slide"
            root.font = ""
        }

        JsonAdapter {
            id: settings
            property bool dnd: false
            property int timeoutCritical: 6000
            property int timeoutNormal: 4000
            property int timeoutLow: 2000
            property string position: "bottom-right"
            property string animation: "slide"
            property string font: ""
        }
    }

    // Drives the "5m ago" line, and garbage-collects arrival times for
    // notifications that are gone. Cheap enough to leave running.
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: {
            root.clockTick++
            const live = {}
            for (const n of server.trackedNotifications.values) {
                if (root.arrivals[n.id] !== undefined) live[n.id] = root.arrivals[n.id]
            }
            root.arrivals = live
        }
    }

    IpcHandler {
        target: "notification-state"
        function toggleDnd(): void { root.toggleDnd() }
        function dnd(): bool { return root.dnd }
        function count(): int { return root.count }
        function clearAll(): void { root.clearAll() }
    }
}
