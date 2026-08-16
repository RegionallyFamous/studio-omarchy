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
  property bool installed: false
  property string installedVersion: ""

  readonly property string pluginRoot: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.regionallyfamous.studio"
  readonly property string updateHelper: pluginRoot
    + "/packaging/arch/studio-omarchy-update"

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\"'\"'") + "'"
  }

  function refreshStatus() {
    statusProc.running = false
    statusProc.running = true
  }

  function open() {
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

  Process {
    id: statusProc
    command: ["pacman", "-Q", "wordpress-studio-omarchy"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.installedVersion = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (!root.installed) root.installedVersion = ""
    }
  }

  Process {
    id: installProc
    command: [
      "omarchy-launch-floating-terminal-with-presentation",
      root.shellQuote(root.updateHelper)
        + "; printf '\nPress Enter to close...'; read -r"
    ]
    onExited: root.refreshStatus()
  }

  Process {
    id: launchProc
    command: ["gtk-launch", "studio"]
  }

  Process {
    id: removeProc
    command: [
      "omarchy-launch-floating-terminal-with-presentation",
      "sudo pacman -Rns wordpress-studio-omarchy; "
        + "printf '\nPress Enter to close...'; read -r"
    ]
    onExited: root.refreshStatus()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: "WordPress Studio"
          color: root.barForeground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.installed
            ? "Installed: " + root.installedVersion
            : "Not installed"
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          width: parent.width
          bordered: true
          focusable: true
          text: root.installed ? "Update Studio" : "Install Studio"
          onClicked: installProc.running = true
        }

        Button {
          width: parent.width
          bordered: true
          focusable: true
          enabled: root.installed
          text: "Launch Studio"
          onClicked: {
            launchProc.running = true
            root.close()
          }
        }

        Button {
          width: parent.width
          bordered: true
          focusable: true
          enabled: root.installed
          text: "Remove Studio"
          onClicked: removeProc.running = true
        }
      }
    }
  }

  Component.onCompleted: refreshStatus()
}
