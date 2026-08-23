import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.regionallyfamous.studio"

  property bool pendingOpen: false

  readonly property bool opened: root.pendingOpen || (panelLoader.item
    ? panelLoader.item.opened === true
    : false)
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) {
      root.pendingOpen = false
      panelLoader.item.open()
    } else {
      root.pendingOpen = true
    }
  }

  function close() {
    root.pendingOpen = false
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) {
      root.pendingOpen = false
      panelLoader.item.toggle()
    } else {
      root.pendingOpen = !root.pendingOpen
    }
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      if (root.pendingOpen) root.open()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf19a"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.body
    tooltipText: "WordPress Studio"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}
