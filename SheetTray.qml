import QtQuick
import qs.Commons

// The sheets tray: a list down the left of the card, most recently used
// first, so the open sheet is always the top row. It only reports what the
// user picked; Omasum.qml owns the list, the files and the switching.
//
// Keys while the list has focus: Up/Down move, Enter opens, Ctrl+Enter
// renames. Ctrl+N, Ctrl+O and Escape are handled by the panel, which sees
// them first.
Item {
  id: tray

  required property var theme
  property var sheets: []
  property string activeId: ""

  signal chosen(string id)
  signal renamed(string id, string name)
  signal createRequested()

  property int selected: 0
  property int editing: -1
  readonly property bool renaming: editing >= 0

  function focusList() {
    editing = -1
    selected = 0
    list.positionViewAtBeginning()
    list.forceActiveFocus()
  }

  function startRename(index) {
    if (index < 0 || index >= sheets.length) return
    selected = index
    editing = index
  }

  function commitRename(index, value) {
    if (editing !== index) return
    editing = -1
    var name = String(value).replace(/^\s+|\s+$/g, "")
    if (name && name !== sheets[index].name) renamed(sheets[index].id, name)
    list.forceActiveFocus()
  }

  function cancelRename() {
    editing = -1
    list.forceActiveFocus()
  }

  function open(index) {
    if (index >= 0 && index < sheets.length) chosen(sheets[index].id)
  }

  // Today shows the time, this year the day, older the year too.
  function whenUsed(iso) {
    var d = new Date(iso)
    if (isNaN(d.getTime())) return ""
    var now = new Date()
    if (d.toDateString() === now.toDateString()) return Qt.formatDateTime(d, "HH:mm")
    var yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
    if (d.toDateString() === yesterday.toDateString()) return "yesterday"
    if (d.getFullYear() === now.getFullYear()) return Qt.formatDateTime(d, "d MMM")
    return Qt.formatDateTime(d, "d MMM yyyy")
  }

  Rectangle {
    anchors.fill: parent
    color: tray.theme.surface
  }

  Rectangle {
    anchors.right: parent.right
    width: 1
    height: parent.height
    color: tray.theme.border
  }

  // Header: the title, then `+` for a new sheet with its key beside it.
  Item {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: tray.theme.rowHeight + tray.theme.spacer

    Text {
      anchors.left: parent.left
      anchors.leftMargin: tray.theme.padX
      anchors.verticalCenter: parent.verticalCenter
      text: "sheets"
      color: tray.theme.accent
      font.family: tray.theme.uiFamily
      font.pixelSize: tray.theme.barTextSize + 1
      font.bold: true
      font.capitalization: Font.AllUppercase
      font.letterSpacing: 1
      textFormat: Text.PlainText
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: tray.theme.padX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Text {
        text: "ctrl n"
        color: tray.theme.muted
        font.family: tray.theme.uiFamily
        font.pixelSize: tray.theme.barTextSize
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: "+"
        color: newMouse.containsMouse ? tray.theme.text : tray.theme.accent
        font.family: tray.theme.uiFamily
        font.pixelSize: tray.theme.textSize + 2
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        MouseArea {
          id: newMouse
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: tray.createRequested()
        }
      }
    }
  }

  ListView {
    id: list
    anchors.top: header.bottom
    anchors.bottom: footer.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.rightMargin: 1
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: tray.sheets
    currentIndex: tray.selected
    highlightFollowsCurrentItem: false

    Keys.onPressed: function(event) {
      var ctrl = event.modifiers & Qt.ControlModifier
      if (event.key === Qt.Key_Up) {
        tray.selected = Math.max(0, tray.selected - 1)
        list.positionViewAtIndex(tray.selected, ListView.Contain)
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        tray.selected = Math.min(tray.sheets.length - 1, tray.selected + 1)
        list.positionViewAtIndex(tray.selected, ListView.Contain)
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (ctrl) tray.startRename(tray.selected)
        else tray.open(tray.selected)
        event.accepted = true
      }
    }

    delegate: Item {
      id: row
      required property int index
      required property var modelData
      readonly property bool active: modelData.id === tray.activeId
      readonly property bool isSelected: index === tray.selected
      width: list.width
      height: tray.theme.rowHeight

      Rectangle {
        anchors.fill: parent
        visible: row.isSelected || rowMouse.containsMouse
        color: tray.theme.overlay
        opacity: row.isSelected ? 1 : 0.5
      }

      // The open sheet carries a bar in accent at the left edge.
      Rectangle {
        visible: row.active
        width: Math.max(2, Style.space(3))
        height: parent.height
        color: tray.theme.accent
      }

      Text {
        visible: tray.editing !== row.index
        anchors.left: parent.left
        anchors.leftMargin: tray.theme.padX
        anchors.right: when.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: row.modelData.name
        color: row.active ? tray.theme.text : tray.theme.muted
        font.family: tray.theme.uiFamily
        font.pixelSize: tray.theme.textSize - 2
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        id: when
        anchors.right: parent.right
        anchors.rightMargin: tray.theme.padX
        anchors.verticalCenter: parent.verticalCenter
        visible: tray.editing !== row.index
        text: tray.whenUsed(row.modelData.used)
        color: tray.theme.muted
        font.family: tray.theme.uiFamily
        font.pixelSize: tray.theme.barTextSize
        textFormat: Text.PlainText
      }

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // A click waits out the double-click interval, so a double-click
        // renames without opening the sheet first.
        onClicked: {
          tray.selected = row.index
          list.forceActiveFocus()
          clickTimer.restart()
        }
        onDoubleClicked: {
          clickTimer.stop()
          tray.startRename(row.index)
        }
        Timer {
          id: clickTimer
          interval: Qt.styleHints.mouseDoubleClickInterval
          onTriggered: tray.open(row.index)
        }
      }

      Loader {
        active: tray.editing === row.index
        anchors.left: parent.left
        anchors.leftMargin: tray.theme.padX
        anchors.right: parent.right
        anchors.rightMargin: tray.theme.padX
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: TextInput {
          text: row.modelData.name
          color: tray.theme.text
          selectionColor: tray.theme.selection
          selectedTextColor: tray.theme.text
          font.family: tray.theme.uiFamily
          font.pixelSize: tray.theme.textSize - 2
          maximumLength: 60
          clip: true
          selectByMouse: true
          Component.onCompleted: { selectAll(); forceActiveFocus() }
          Keys.onReturnPressed: tray.commitRename(row.index, text)
          Keys.onEnterPressed: tray.commitRename(row.index, text)
          // Clicking elsewhere keeps what was typed.
          onActiveFocusChanged: if (!activeFocus) tray.commitRename(row.index, text)

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.bottom
            anchors.topMargin: Style.space(2)
            height: 1
            color: tray.theme.accent
          }
        }
      }
    }
  }

  // Footer: the keys, in the bar's style.
  Text {
    id: footer
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: tray.theme.padX
    anchors.rightMargin: tray.theme.padX
    height: tray.theme.rowHeight + tray.theme.spacer
    verticalAlignment: Text.AlignVCenter
    text: tray.renaming ? "↵ save · esc cancel" : "↵ open · ctrl ↵ rename"
    color: tray.theme.muted
    font.family: tray.theme.uiFamily
    font.pixelSize: tray.theme.barTextSize
    elide: Text.ElideRight
    textFormat: Text.PlainText
  }
}
