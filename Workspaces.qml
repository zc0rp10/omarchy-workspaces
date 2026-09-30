import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  // Quickshell only learns the focused monitor and each monitor's workspace from events, so
  // after the shell starts they stay null until the first switch. Ask Hyprland once to cover that.
  property string startupMonitor: ""
  property int startupWorkspace: -1
  property var startupActive: ({})
  property var monitorGeometry: ({})

  Process {
    id: focusProbe
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var monitors = JSON.parse(text)
        var active = {}
        var geometry = {}
        for (var i = 0; i < monitors.length; i++) {
          var m = monitors[i]
          active[m.name] = m.activeWorkspace.id
          geometry[m.name] = { x: m.x, y: m.y, width: m.width / m.scale, height: m.height / m.scale }
          if (!monitors[i].focused) continue
          root.startupMonitor = monitors[i].name
          root.startupWorkspace = monitors[i].activeWorkspace.id
        }
        root.startupActive = active
        root.monitorGeometry = geometry
      }
    }
  }


  function currentMonitor() {
    if (Hyprland.focusedMonitor) return Hyprland.focusedMonitor
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].name === root.startupMonitor) return monitors[i]
    }

    return null
  }

  function currentWorkspaceId() {
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : root.startupWorkspace
  }

  function activeWorkspaceId(monitor) {
    if (monitor.activeWorkspace) return monitor.activeWorkspace.id
    var id = root.startupActive[monitor.name]
    return id === undefined ? -1 : id
  }

  // Logical rectangle, from Hyprland's own data: Quickshell's copy is wrong until the first event
  function monitorRect(monitor) {
    var g = root.monitorGeometry[monitor.name]
    if (g) return g
    var scale = monitor.scale > 0 ? monitor.scale : 1
    return { x: monitor.x, y: monitor.y, width: monitor.width / scale, height: monitor.height / scale }
  }

  // Groups spans that overlap into ordered bands (columns or rows); touching spans stay apart.
  // Returns each span's band index and the band count.
  function bands(spans) {
    var order = spans.map(function(_, i) { return i })
    order.sort(function(a, b) { return spans[a].start - spans[b].start })
    var index = []
    var band = -1
    var end = -Infinity
    for (var i = 0; i < order.length; i++) {
      var span = spans[order[i]]
      if (span.start >= end) band++
      end = Math.max(end, span.end)
      index[order[i]] = band
    }

    return { index: index, count: band + 1 }
  }

  // Where the monitor showing workspace `id` sits in the whole layout, as a cell in a
  // columns x rows grid, or null if it isn't showing on another monitor. Absolute, so each
  // monitor keeps the same cell whichever one is focused.
  function slotForWorkspace(id) {
    var monitors = Hyprland.monitors.values
    var focused = root.currentMonitor()
    var rects = []
    var target = -1
    for (var i = 0; i < monitors.length; i++) {
      rects.push(root.monitorRect(monitors[i]))
      if (root.activeWorkspaceId(monitors[i]) === id) target = i
    }

    if (target < 0 || monitors[target] === focused) return null

    var cols = root.bands(rects.map(function(r) { return { start: r.x, end: r.x + r.width } }))
    var rows = root.bands(rects.map(function(r) { return { start: r.y, end: r.y + r.height } }))
    return { col: cols.index[target], cols: cols.count, row: rows.index[target], rows: rows.count }
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  // Quickshell only tracks monitor.activeWorkspace on workspace switches, so moving a
  // workspace to another monitor or changing the layout leaves it stale until refreshed.
  // A runtime layout change emits no monitor event, but the shell rebuilds the bar.
  Component.onCompleted: {
    Hyprland.refreshMonitors()
    focusProbe.running = true
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      switch (event.name) {
      case "moveworkspacev2":
      case "configreloaded":
      case "monitoraddedv2":
      case "monitorremovedv2":
        Hyprland.refreshMonitors()
        focusProbe.running = true
      }
    }
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        id: button
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: root.currentWorkspaceId() === modelData
        readonly property var slot: focused ? null : root.slotForWorkspace(modelData)
        readonly property bool visibleElsewhere: slot !== null

        bar: root.bar
        // filled square = focused; partly filled square = showing on another monitor, filled
        // in that monitor's cell of the layout (drawn below, the font has no such glyphs)
        text: focused || visibleElsewhere ? "\uDB85\uDCFB" : (modelData === 10 ? "0" : String(modelData))
        labelVisible: !focused && !visibleElsewhere
        opacity: occupied || focused || visibleElsewhere ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }

        // Drawn instead of using the font glyph so the focused and half-filled squares are
        // identical, and snapped to physical pixels so the halves split exactly 50/50
        Item {
          id: square
          // The window's ratio, not Screen's: Screen reports 2 on a 1.25-scaled output
          readonly property real dpr: button.Window.window && button.Window.window.devicePixelRatio > 0 ? button.Window.window.devicePixelRatio : 1
          readonly property int sizePx: 2 * Math.round(button.fontSize * 0.76 * dpr / 2)
          readonly property real size: sizePx / dpr
          readonly property real radius: Math.round(sizePx * 0.28) / dpr
          // Scene position of the button, so the square can land on whole physical pixels.
          // Ancestors move after this is created and emit nothing, so re-read it when the bar
          // redraws (which only happens when something in it changes).
          property point origin: Qt.point(0, 0)

          Connections {
            target: button.Window.window

            function onFrameSwapped() {
              var p = button.mapToItem(null, 0, 0)
              if (p.x !== square.origin.x || p.y !== square.origin.y) square.origin = p
            }
          }




          function snap(value) { return Math.round(value * dpr) / dpr }

          visible: button.focused || button.visibleElsewhere
          width: size
          height: size
          x: snap(origin.x + (button.width - size) / 2) - origin.x
          y: snap(origin.y + (button.height - size) / 2) - origin.y

          Rectangle {
            anchors.fill: parent
            radius: square.radius
            color: button.focused ? button.foreground : "transparent"
            border.color: button.foreground
            border.width: Math.max(1, Math.round(square.sizePx * 0.1)) / square.dpr
          }

          // Clip a filled rounded square down to the monitor's cell, on whole physical pixels
          Item {
            readonly property var slot: button.slot
            readonly property int x0: slot ? Math.round(slot.col * square.sizePx / slot.cols) : 0
            readonly property int x1: slot ? Math.round((slot.col + 1) * square.sizePx / slot.cols) : 0
            readonly property int y0: slot ? Math.round(slot.row * square.sizePx / slot.rows) : 0
            readonly property int y1: slot ? Math.round((slot.row + 1) * square.sizePx / slot.rows) : 0

            visible: !button.focused && slot !== null
            clip: true
            x: x0 / square.dpr
            y: y0 / square.dpr
            width: (x1 - x0) / square.dpr
            height: (y1 - y0) / square.dpr

            Rectangle {
              x: -parent.x
              y: -parent.y
              width: square.size
              height: square.size
              radius: square.radius
              color: button.foreground
            }
          }

        }
      }
    }
  }
}
