import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.regionallyfamous.studio"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool statusReady: false
  property bool statusError: false
  property bool installed: false
  property string installedVersion: ""
  property int actionIndex: 0

  readonly property string pluginRoot: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.regionallyfamous.studio"
  readonly property string statusHelper: pluginRoot + "/scripts/status.sh"
  readonly property string actionHelper: pluginRoot + "/scripts/action.sh"

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(raw) {
    var value = String(raw || "").trim()
    statusReady = true
    statusError = true
    installed = false
    installedVersion = ""

    if (value === "missing") {
      statusError = false
      return
    }
    if (value.length > 96) return
    var match = /^installed\t([A-Za-z0-9._+:-]{1,64})$/.exec(value)
    if (!match) return

    statusError = false
    installed = true
    installedVersion = match[1]
  }

  function open() {
    actionIndex = 0
    statusReady = false
    statusError = false
    installed = false
    installedVersion = ""
    root.controller.show()
    refreshStatus()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) close()
    else open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function actionEnabled(index) {
    return index === 0 || root.installed
  }

  function moveAction(direction) {
    var next = root.actionIndex
    for (var count = 0; count < 3; count++) {
      next = (next + direction + 3) % 3
      if (root.actionEnabled(next)) {
        root.actionIndex = next
        return
      }
    }
  }

  function runAction(action) {
    if (!root.bar) return
    root.close()
    root.bar.run(Util.shellQuote(root.actionHelper) + " " + action)
  }

  function activateAction() {
    if (root.actionIndex === 0) root.runAction("update")
    else if (root.actionIndex === 1 && root.installed) root.runAction("launch")
    else if (root.actionIndex === 2 && root.installed) root.runAction("remove")
  }

  Process {
    id: statusProc
    command: [root.statusHelper]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.applyStatus("error")
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: root.refreshStatus()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveAction(dy > 0 ? 1 : -1)
      }
      onActivateRequested: root.activateAction()

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "\uf19a"
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - parent.spacing - Style.space(28)
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "WordPress Studio"
              textFormat: Text.PlainText
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              text: !root.statusReady
                ? "Checking installation…"
                : (root.statusError
                  ? "Unable to check installation"
                  : (root.installed
                    ? "Installed " + root.installedVersion + " · Native Wayland"
                    : "Not installed"))
              textFormat: Text.PlainText
              color: root.barForeground
              opacity: 0.82
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.weight: Font.Medium
              wrapMode: Text.WordWrap
            }
          }
        }

        Button {
          width: parent.width
          bordered: true
          hasCursor: root.actionIndex === 0
          text: root.installed
            ? "Update Studio"
            : (root.statusError ? "Install or Update Studio" : "Install Studio")
          onHovered: function(isHovered) {
            if (isHovered) root.actionIndex = 0
          }
          onClicked: root.runAction("update")
        }

        Button {
          width: parent.width
          bordered: true
          enabled: root.installed
          hasCursor: root.actionIndex === 1
          text: "Launch Studio"
          onHovered: function(isHovered) {
            if (isHovered && root.installed) root.actionIndex = 1
          }
          onClicked: if (root.installed) root.runAction("launch")
        }

        Button {
          width: parent.width
          bordered: true
          enabled: root.installed
          hasCursor: root.actionIndex === 2
          text: "Remove Studio"
          onHovered: function(isHovered) {
            if (isHovered && root.installed) root.actionIndex = 2
          }
          onClicked: if (root.installed) root.runAction("remove")
        }

        Text {
          width: parent.width
          text: "↑/↓ choose · Enter run · Esc close"
          textFormat: Text.PlainText
          color: Qt.darker(root.barForeground, 1.45)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
