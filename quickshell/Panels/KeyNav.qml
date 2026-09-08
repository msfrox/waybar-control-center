// KeyNav — ONE keyboard cursor for a panel made of Repeater rows.
//
// WHY THIS EXISTS. The 2026-09-07 keyboard reachability audit
// (brilliant/docs/33-input-reachability-and-keybinds.md §1) found the same
// defect three times: Audio, Bluetooth and Notifications are each a stack of
// `Repeater`s over live arrays, every row a bare `MouseArea`, with no Tab, no
// arrows and no Enter. The audit's own words: "these cannot be solved with a
// chord ... no keybind can stand in for 'pick the third item in a list that
// changes every time you look at it'."
//
// They are three instances of one problem, so they get one mechanism. This
// file is that mechanism, and it is deliberately NOT three ad-hoc
// implementations — BUGS.md already records what that costs here ("one correct
// call site does not protect the second one", the window.close drift).
//
// --- WHAT IT OWNS, AND WHAT IT REFUSES TO OWN ----------------------------
//
// It owns the CURSOR: where it is, how it moves, and how it survives a list
// that changes underneath it. It owns nothing about what a row *is* or what
// activating one *does*, because those differ per panel and pretending they
// don't is how a shared component becomes a switch statement about its callers.
//
// So the panel declares its sections in visual order, KeyNav flattens them
// into one index space, and the panel's own `Keys.onPressed` decides what
// Enter means for the section the cursor happens to be in.
//
//     KeyNav {
//         id: nav
//         sections: [
//             { id: "connected",  items: root.connected  },
//             { id: "known",      items: root.known      },
//             { id: "discovered", items: root.discovered }
//         ]
//     }
//
//     // in a row:  highlighted: nav.isCurrent("known", index)
//     // on hover:  onEntered: nav.setCurrent("known", index)
//     // on Enter:  switch (nav.currentSection) { ... nav.currentItem ... }
//
// --- THE FLAT INDEX, AND WHY IT IS ONE NUMBER ----------------------------
//
// Same reasoning as SwitcherWindow.qml, which the audit named as the one
// surface already built right and told us to copy: windows and workspaces
// share one `entries` array and one `selectedIndex`, so Tab/next/prev need no
// branch for "which half am I in". Only *commit* branches, because focusing a
// window and switching a workspace are genuinely different things.
//
// Identical here. Moving the cursor never needs to know it just crossed from
// "Paired" into "Available"; only activation does.
//
// --- -1 IS A REAL STATE, NOT AN ERROR ------------------------------------
//
// A panel opens with `index === -1`: no cursor, nothing highlighted. This is
// deliberate and it is the difference between a panel that opens usable by
// mouse and one that opens with a row already lit up as though something had
// been chosen. The first Down/Tab lands on row 0 rather than row 1 — so the
// first list item is reachable in one keystroke, which it would not be if the
// cursor started at 0 and Down moved off it.
//
// (SwitcherWindow deliberately does the opposite — it opens ON entry 1,
// because Alt-Tab that lands on the window you are already in is a no-op
// gesture. Different surface, different correct answer, and worth naming so
// the divergence reads as a decision rather than a copy that drifted.)
//
// --- THE LIST CHANGES WHILE YOU ARE STANDING ON IT -----------------------
//
// This is the part an ad-hoc implementation gets wrong, and it is the whole
// reason the audit called these lists out separately from everything else:
// they are LIVE. A Bluetooth scan adds rows every second or two. A device
// disconnects and moves from "Connected" to "Paired" — a different section,
// a different flat index, the same object. A notification arrives or is
// dismissed. So the cursor cannot simply be an integer that a panel sets and
// forgets.
//
// Two protections, both below:
//   1. `count` shrinking clamps the cursor back inside the list instead of
//      leaving it pointing past the end, where `current` would be undefined
//      and Enter would do nothing with no way to tell why.
//   2. `keepOn` re-finds a specific item after the model churns, so a panel
//      that knows the identity it wants to stay on can hold the cursor there
//      across a re-section rather than watching it jump.
//
// --- POINTER AND KEYBOARD SHARE THE CURSOR, THEY DO NOT TAKE TURNS -------
//
// ADR-0018 rule 4: "devices compose; they do not take turns." A row's hover
// handler calls `setCurrent()`, so moving the mouse moves the same cursor the
// arrow keys move, and there is never a lit keyboard row in one place and a
// hovered row in another arguing about which one Enter means. One cursor, two
// ways to move it — exactly what SwitcherWindow does with `onHoverIndex`.

import QtQuick

QtObject {
    id: nav

    // --- INPUT: the panel's navigable content, in the order it is drawn ---
    //
    // [{ id: "<section name>", items: <array> }, ...]
    //
    // Sections with zero items are legal and cost nothing — they contribute no
    // indices. That matters because these panels already hide empty sections
    // with `visible:` bindings, and the cursor must never be able to land on a
    // row that is not on screen. Passing the same live arrays the Repeaters
    // use keeps those two facts the same fact, rather than two lists that can
    // disagree.
    property var sections: []

    // --- THE CURSOR ---
    //
    // -1 means "no cursor". See the header: this is a state, not an error.
    property int index: -1

    // --- DERIVED: one flat array, one index space ---
    //
    // [{ section: "known", row: 2, item: <the object> }, ...]
    readonly property var flat: {
        const out = []
        const secs = nav.sections || []
        for (let s = 0; s < secs.length; s++) {
            const sec = secs[s]
            if (!sec || !sec.items)
                continue
            const items = sec.items
            for (let r = 0; r < items.length; r++)
                out.push({ section: `${sec.id}`, row: r, item: items[r] })
        }
        return out
    }

    readonly property int count: nav.flat.length
    readonly property var current: (nav.index >= 0 && nav.index < nav.count) ? nav.flat[nav.index] : null
    readonly property string currentSection: nav.current ? nav.current.section : ""
    readonly property int currentRow: nav.current ? nav.current.row : -1
    readonly property var currentItem: nav.current ? nav.current.item : null

    // Emitted whenever the cursor lands somewhere new, including via hover.
    // A panel with a scrollable body connects this to "scroll the current row
    // into view" — without it, arrowing past the bottom of a Flickable moves a
    // highlight nobody can see.
    signal moved(int index)

    // ⚠️ THE LIVE-LIST GUARD. `count` drops when a device disconnects, a
    // notification is dismissed, or a scan's results are replaced wholesale.
    // Left alone the cursor keeps its old integer and points past the end:
    // `current` goes null, the highlight vanishes, and Enter silently does
    // nothing — which reads from the outside as "keyboard nav is broken", the
    // hardest kind of report to act on. Clamp to the last real row instead.
    onCountChanged: {
        if (nav.index >= nav.count)
            nav.index = nav.count - 1
    }

    // --- QUERIES A ROW ASKS ---

    function isCurrent(sectionId: string, row: int): bool {
        const c = nav.current
        return c !== null && c.section === `${sectionId}` && c.row === row
    }

    function indexOf(sectionId: string, row: int): int {
        const f = nav.flat
        const want = `${sectionId}`
        for (let i = 0; i < f.length; i++)
            if (f[i].section === want && f[i].row === row)
                return i
        return -1
    }

    // --- MOVING THE CURSOR ---

    function setIndex(i: int): void {
        if (i < 0 || i >= nav.count || i === nav.index)
            return
        nav.index = i
        nav.moved(i)
    }

    // What a row's hover handler calls. Same cursor as the keys move.
    function setCurrent(sectionId: string, row: int): void {
        nav.setIndex(nav.indexOf(sectionId, row))
    }

    // Wraps, like SwitcherWindow's advance(). A panel list is short enough
    // that wrapping is faster than clamping and nobody loses their place.
    //
    // From -1 (no cursor), a forward move lands on 0 and a backward move on
    // the last row — so Down and Up are both one keystroke to a useful place
    // on a freshly-opened panel.
    function moveBy(delta: int): void {
        const n = nav.count
        if (n === 0)
            return
        if (nav.index < 0) {
            nav.setIndex(delta >= 0 ? 0 : n - 1)
            return
        }
        nav.setIndex(((nav.index + delta) % n + n) % n)
    }

    function first(): void { nav.setIndex(nav.count > 0 ? 0 : -1) }
    function last(): void { nav.setIndex(nav.count - 1) }

    // Drop the cursor entirely. Panels call this on close, so reopening starts
    // clean rather than resuming a highlight from a list that has since moved
    // on — and on Escape-with-a-cursor, which is the natural "put the keyboard
    // away, I'm using the mouse" gesture.
    function clear(): void {
        if (nav.index === -1)
            return
        nav.index = -1
        nav.moved(-1)
    }

    // Hold the cursor on ONE object across a model churn — the disconnect case
    // from the header, where the same device moves from "Connected" to
    // "Paired" and its flat index changes underneath a cursor that never moved.
    // Identity comparison, so it works on the live QObjects these panels
    // already bind to. No-op when the object is gone, leaving the clamp above
    // to do the safe thing.
    function keepOn(item: var): void {
        if (item === null || item === undefined)
            return
        const f = nav.flat
        for (let i = 0; i < f.length; i++) {
            if (f[i].item === item) {
                nav.setIndex(i)
                return
            }
        }
    }
}
