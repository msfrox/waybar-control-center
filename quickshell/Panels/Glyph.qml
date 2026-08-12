// A Material Icons Round glyph, accent-coloured and centred.
//
// The panel vocabulary: settings, chevron_right, expand_more, bolt. Use FaGlyph
// instead when the icon has to match one the BAR is already drawing, since the
// bar's format strings are Font Awesome.
//
// ONE TRAP, banked the hard way: a MISSING ligature in this font renders as the
// literal WORD, not as tofu — `inventory_2` is not in the installed
// MaterialIconsRound-Regular.otf and shows up as the text "inventory_2" in the
// middle of a panel. Check a new name renders before shipping it.

import QtQuick
import qs.Panels

Text {
    font.family: PanelStyle.iconFamily
    font.pixelSize: PanelStyle.iconSize
    color: PanelStyle.textAccent
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
}
