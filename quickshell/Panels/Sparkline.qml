// A small rolling history graph: a series of samples drawn as a filled line,
// the way btop's braille throughput graphs read at a glance but compact
// enough for a panel row.
//
//     Sparkline {
//         Layout.fillWidth: true
//         samples: netHistory.down          // oldest first, newest last
//         lineColor: Theme.primary
//     }
//
// Deliberately generic — this draws today's network throughput graph, but
// carries no network-specific assumptions, so the same component is what a
// later CPU or RAM history graph reuses rather than growing its own Canvas
// code. The caller owns sampling cadence and buffer length entirely; this
// only draws whatever array it's handed.

import QtQuick
import qs.CustomTheme
import qs.Panels

Item {
    id: spark

    property var samples: []
    // 0 autoscales to the highest sample currently in the buffer, which is
    // right for a rate graph with no natural ceiling. Set a fixed value for
    // a series that already has one, like a 0-100 percentage.
    property real maxValue: 0
    property color lineColor: Theme.primary
    property real lineWidth: 1.5
    property real fillOpacity: 0.18

    implicitHeight: 28

    readonly property real effectiveMax: {
        if (spark.maxValue > 0)
            return spark.maxValue
        let m = 0
        for (let i = 0; i < spark.samples.length; i++)
            if (spark.samples[i] > m) m = spark.samples[i]
        return m > 0 ? m : 1
    }

    Canvas {
        id: canvas
        anchors.fill: parent

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        // Canvas only repaints when told to - a bound property changing
        // underneath it is invisible without this.
        Connections {
            target: spark
            function onSamplesChanged() { canvas.requestPaint() }
            function onEffectiveMaxChanged() { canvas.requestPaint() }
            function onLineColorChanged() { canvas.requestPaint() }
        }

        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            const pts = spark.samples
            if (pts.length < 2 || width <= 0 || height <= 0)
                return

            const stepX = width / (pts.length - 1)
            const max = spark.effectiveMax
            const yOf = v => height - Math.max(0, Math.min(1, v / max)) * height

            ctx.beginPath()
            ctx.moveTo(0, yOf(pts[0]))
            for (let i = 1; i < pts.length; i++)
                ctx.lineTo(i * stepX, yOf(pts[i]))

            ctx.lineJoin = "round"
            ctx.lineWidth = spark.lineWidth
            ctx.strokeStyle = spark.lineColor
            ctx.stroke()

            ctx.lineTo(width, height)
            ctx.lineTo(0, height)
            ctx.closePath()
            ctx.fillStyle = PanelStyle.withAlpha(spark.lineColor, spark.fillOpacity)
            ctx.fill()
        }
    }
}
