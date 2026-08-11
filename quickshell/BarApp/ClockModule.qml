// The clock, and the notification centre's trigger.
//
// Reproduces Waybar's `"{:%a %d %I:%M:%S}"` — "Tue 11 07:33:12". That is a 12-hour
// clock with NO am/pm marker, which Qt's format strings cannot express: "hh" is
// 12-hour only when the pattern also contains AP/ap, and adding AP would change what
// the bar shows. So the hour is computed and the rest is formatted.

import Quickshell
import QtQuick
import qs.CustomTheme

BarButton {
    id: clock

    // #clock in the Waybar CSS: an opaque pill with a 2px border, 16px text, and a
    // 115px floor so the strip does not twitch as the seconds change width.
    pill: true
    labelSize: 16
    minWidth: 115
    hpadding: 10

    // Seconds are on display, so the tick has to be per-second. SystemClock only
    // wakes as often as its precision demands, unlike a Timer left running at 1000ms.
    SystemClock {
        id: sysclock
        precision: SystemClock.Seconds
    }

    label: {
        const d = sysclock.date
        // 0 -> 12, 13 -> 1. Matches %I, including the zero padding.
        const h12 = ((d.getHours() + 11) % 12) + 1
        return Qt.formatDateTime(d, "ddd dd ")
             + String(h12).padStart(2, "0")
             + Qt.formatDateTime(d, ":mm:ss")
    }
}
