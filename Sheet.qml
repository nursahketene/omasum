import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "engine.js" as Engine

// The sheet: one transparent TextEdit holding the whole document over a Text
// that paints the coloured copy, with the result column beside it. The two
// layers share metrics, never state — the markup is rebuilt from engine.js
// on every change and never touches the editor's text, cursor or selection.
//
// TextEdit has no lineHeight property, so the 30px row comes from a block
// format instead: the editor runs in RichText mode where every line is a
// <div style="line-height:30px; white-space:pre">. Enter inherits the block
// format, and paste is intercepted so only plain text ever enters the
// document. The plain text is read back with getText() and never from
// `text`, which is HTML in this mode.
Item {
  id: sheet

  required property var theme
  property var rates: null

  // The document text is the only state.
  property string text: ""
  readonly property int lineCount: result.lines.length
  readonly property var names: result.names
  readonly property int resultCount: result.resultCount
  readonly property bool empty: editor.length === 0

  property var result: ({ lines: [], names: [], resultCount: 0 })
  property string markup: ""
  property int copiedLine: -1
  property string copiedValue: ""

  signal edited()
  signal copied(string value)
  // Tab leaves the editor for the bar controls; the panel decides where.
  signal tabPressed(bool backwards)

  readonly property int rowHeight: theme.rowHeight
  readonly property int spacer: theme.spacer
  readonly property int resultWidth: theme.resultWidth
  readonly property int editorWidth: width - resultWidth

  // The RichText editor lays the natural line at the bottom of its
  // fixed-height block; a Text with a fixed lineHeight lays it at the top.
  // Every painted layer takes this inset so it lands where the editor's
  // (transparent) glyphs are.
  FontMetrics {
    id: metrics
    font.family: sheet.theme.monoFamily
    font.pixelSize: sheet.theme.textSize
  }
  readonly property int lineInset: Math.max(0, rowHeight - Math.ceil(metrics.height))

  function focusEditor() {
    editor.forceActiveFocus()
  }

  // ------------------------------------------------------------ document

  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function lineHtml(line) {
    return '<div style="line-height:' + rowHeight + 'px; white-space:pre">' + escapeHtml(line) + "</div>"
  }

  function toHtml(plain) {
    var lines = String(plain).split("\n")
    var out = ""
    for (var i = 0; i < lines.length; i++) out += lineHtml(lines[i])
    return out
  }

  // Block and line separators come back from getText as U+2029 / U+2028.
  // Built with RegExp() because QML's parser reads those characters inside
  // a regex literal as line terminators.
  readonly property var separators: new RegExp("[\\u2029\\u2028]", "g")
  readonly property var thinSpaces: new RegExp("\\u2009", "g")
  function plainText() {
    return editor.getText(0, editor.length).replace(separators, "\n")
  }

  // Replaces the whole document. Used on load; resets the undo stack.
  function setText(value) {
    editor.text = toHtml(value)
    editor.cursorPosition = editor.length
  }

  // Clean sheet goes through the document cursor so the TextEdit's own undo
  // stack covers it; `lastCleared` is the belt to that brace.
  property string lastCleared: ""
  function clear() {
    if (editor.length === 0) return
    lastCleared = plainText()
    editor.remove(0, editor.length)
    editor.cursorPosition = 0
    editor.forceActiveFocus()
  }

  function insertPlain(position, value) {
    var s = String(value || "").replace(/\r\n?/g, "\n")
    if (!s) return
    editor.insert(position, toHtml(s))
  }

  function pasteAtCursor(value) {
    if (editor.selectionStart !== editor.selectionEnd) {
      var start = editor.selectionStart
      editor.remove(editor.selectionStart, editor.selectionEnd)
      editor.cursorPosition = start
    }
    insertPlain(editor.cursorPosition, value)
  }

  // Middle-click pastes the primary selection, read through wl-paste since
  // Qt does not hand the primary selection to QML.
  property int primaryPastePosition: -1
  Process {
    id: primaryPaste
    command: ["wl-paste", "--primary", "--no-newline"]
    stdout: StdioCollector {
      id: primaryOut
      waitForEnd: true
    }
    onExited: function(code) {
      if (code === 0 && sheet.primaryPastePosition >= 0) {
        var at = Math.min(sheet.primaryPastePosition, editor.length)
        sheet.insertPlain(at, primaryOut.text)
      }
      sheet.primaryPastePosition = -1
    }
  }

  // ------------------------------------------------------------ evaluation

  // Sequence: read the text, evaluate, rebuild the markup, and the result
  // rows and bottom bar follow from bindings on `result`.
  function evaluate() {
    text = plainText()
    result = Engine.evaluateSheet(text, { rates: sheet.rates })
    markup = Engine.renderMarkup(result, theme.palette)
  }

  onRatesChanged: evaluate()
  Connections {
    target: theme
    function onPaletteChanged() { sheet.markup = Engine.renderMarkup(sheet.result, sheet.theme.palette) }
    // A changed row height needs new block formats; the text is re-set,
    // which costs the undo stack. Only happens on a font size change.
    function onRowHeightChanged() { sheet.setText(sheet.text) }
  }
  Component.onCompleted: evaluate()

  function copyLine(index) {
    var line = result.lines[index]
    if (!line || !line.plain) return
    Quickshell.execDetached(["wl-copy", "--", line.plain])
    copiedLine = index
    copiedValue = line.plain
    copiedTimer.restart()
    copied(line.plain)
  }

  Timer {
    id: copiedTimer
    interval: 1800
    onTriggered: { sheet.copiedLine = -1; sheet.copiedValue = "" }
  }

  function keepCursorVisible() {
    var cr = editor.cursorRectangle
    var top = spacer + cr.y
    var bottom = top + rowHeight
    if (top < flick.contentY) flick.contentY = Math.max(0, top - spacer)
    else if (bottom > flick.contentY + flick.height) flick.contentY = bottom - flick.height + spacer
    // Horizontal: long lines clip rather than wrap, so slide the editor
    // layers under their clip to keep the caret in view.
    var visibleLeft = editorColumn.hOffset
    var visibleRight = visibleLeft + editorColumn.width
    if (cr.x < visibleLeft + theme.padX) editorColumn.hOffset = Math.max(0, cr.x - theme.padX)
    else if (cr.x + 2 > visibleRight - theme.padX) editorColumn.hOffset = cr.x + 2 - editorColumn.width + theme.padX
  }

  // ------------------------------------------------------------ layout

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: Math.max(height, sheet.spacer + sheet.lineCount * sheet.rowHeight + sheet.spacer)
    boundsBehavior: Flickable.StopAtBounds
    interactive: false

    // Click below the last line puts the cursor at the end of the sheet.
    // Wheel scrolls; dragging is left to the editor for selection.
    MouseArea {
      anchors.fill: parent
      onClicked: function(mouse) {
        if (mouse.y < sheet.spacer + sheet.lineCount * sheet.rowHeight) return
        editor.cursorPosition = editor.length
        editor.forceActiveFocus()
      }
      onWheel: function(wheel) {
        var max = Math.max(0, flick.contentHeight - flick.height)
        var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y
        flick.contentY = Math.max(0, Math.min(max, flick.contentY - delta / 120 * sheet.rowHeight * 2))
        wheel.accepted = true
      }
    }

    // The column rule runs bar to bar, through the spacer and the filler.
    Rectangle {
      x: sheet.editorWidth
      y: 0
      width: 1
      height: flick.contentHeight
      color: sheet.theme.border
    }

    // The lit row after a copy, drawn under both columns.
    Rectangle {
      visible: sheet.copiedLine >= 0
      x: 0
      y: sheet.spacer + sheet.copiedLine * sheet.rowHeight
      width: flick.width
      height: sheet.rowHeight
      color: sheet.theme.surface
    }

    Item {
      id: editorColumn
      property real hOffset: 0
      x: 0
      y: sheet.spacer
      width: sheet.editorWidth
      height: sheet.lineCount * sheet.rowHeight
      clip: true

      Item {
        x: -editorColumn.hOffset
        width: Math.max(editorColumn.width, editor.contentWidth + sheet.theme.padX * 2)
        height: editorColumn.height

        // Ghost line for an empty sheet, cleared on the first keystroke.
        Text {
          visible: sheet.empty
          x: sheet.theme.padX
          height: sheet.rowHeight
          topPadding: sheet.lineInset
          lineHeight: sheet.rowHeight
          lineHeightMode: Text.FixedHeight
          text: "# a scratch sheet — every line is live"
          color: sheet.theme.muted
          font.family: sheet.theme.monoFamily
          font.pixelSize: sheet.theme.textSize
          font.italic: true
          textFormat: Text.PlainText
        }

        Text {
          id: painted
          anchors.fill: parent
          leftPadding: sheet.theme.padX
          rightPadding: sheet.theme.padX
          topPadding: sheet.lineInset
          textFormat: Text.StyledText
          text: sheet.markup
          color: sheet.theme.text
          font.family: sheet.theme.monoFamily
          font.pixelSize: sheet.theme.textSize
          lineHeight: sheet.rowHeight
          lineHeightMode: Text.FixedHeight
          wrapMode: Text.NoWrap
        }

        TextEdit {
          id: editor
          anchors.fill: parent
          leftPadding: sheet.theme.padX
          rightPadding: sheet.theme.padX
          color: "transparent"
          selectionColor: sheet.theme.selection
          selectedTextColor: "transparent"
          font.family: sheet.theme.monoFamily
          font.pixelSize: sheet.theme.textSize
          wrapMode: TextEdit.NoWrap
          textFormat: TextEdit.RichText
          text: sheet.lineHtml("")
          selectByMouse: true
          persistentSelection: false
          // The editor sizes the delegate to the natural line; the caret
          // is drawn the height of the text, centred on it.
          cursorDelegate: Item {
            width: Math.max(1, Style.space(2))
            height: editor.cursorRectangle.height
            visible: editor.activeFocus
            Rectangle {
              width: parent.width
              height: sheet.theme.textSize + Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              color: sheet.theme.accent
              SequentialAnimation on opacity {
                running: editor.activeFocus
                loops: Animation.Infinite
                PropertyAction { value: 1 }
                PauseAnimation { duration: 560 }
                PropertyAction { value: 0 }
                PauseAnimation { duration: 400 }
              }
            }
          }

          onTextChanged: {
            sheet.evaluate()
            sheet.edited()
          }
          onCursorRectangleChanged: sheet.keepCursorVisible()

          Keys.onPressed: function(event) {
            var ctrl = event.modifiers & Qt.ControlModifier
            var shift = event.modifiers & Qt.ShiftModifier
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              sheet.tabPressed(event.key === Qt.Key_Backtab || !!shift)
              event.accepted = true
              return
            }
            // Paste as plain text: the document is rich only for its row
            // height, and pasted markup must never reach it.
            if ((ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) {
              sheet.pasteAtCursor(Quickshell.clipboardText)
              event.accepted = true
              return
            }
            // Fallback undo for a programmatic clear, should the document's
            // own stack not cover it.
            if (ctrl && event.key === Qt.Key_Z && editor.length === 0
                && sheet.lastCleared.length > 0 && !editor.canUndo) {
              var restore = sheet.lastCleared
              sheet.lastCleared = ""
              sheet.insertPlain(0, restore)
              editor.cursorPosition = editor.length
              event.accepted = true
            }
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.MiddleButton
            onClicked: function(mouse) {
              sheet.primaryPastePosition = editor.positionAt(mouse.x, mouse.y)
              editor.cursorPosition = sheet.primaryPastePosition
              editor.forceActiveFocus()
              primaryPaste.running = true
            }
          }
        }
      }
    }

    // Result column: one row per line, right-aligned, ellipsised.
    Item {
      x: sheet.editorWidth
      y: sheet.spacer
      width: sheet.resultWidth

      Repeater {
        model: sheet.result.lines

        delegate: Item {
          id: row
          required property int index
          required property var modelData

          readonly property bool hasValue: modelData.kind === "assign" || modelData.kind === "value"
          readonly property bool isError: modelData.kind === "error"
          readonly property bool staleRate: hasValue && modelData.usedRate && !!sheet.rates && !!sheet.rates.stale
          readonly property color valueColor: isError ? sheet.theme.err
            : modelData.kind === "assign" ? sheet.theme.ok : sheet.theme.text

          y: index * sheet.rowHeight
          width: sheet.resultWidth
          height: sheet.rowHeight

          Rectangle {
            anchors.fill: parent
            visible: row.hasValue && rowMouse.containsMouse && sheet.copiedLine !== row.index
            color: sheet.theme.surface
            opacity: 0.6
          }

          Text {
            id: rateTag
            visible: row.staleRate
            anchors.right: valueText.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: "rate"
            color: sheet.theme.warn
            font.family: sheet.theme.uiFamily
            font.pixelSize: sheet.theme.barTextSize
            textFormat: Text.PlainText

            MouseArea {
              id: rateMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }

            Rectangle {
              visible: rateMouse.containsMouse
              anchors.bottom: parent.top
              anchors.bottomMargin: Style.space(4)
              anchors.right: parent.right
              width: rateTip.implicitWidth + Style.space(16)
              height: rateTip.implicitHeight + Style.space(8)
              radius: Style.space(4)
              color: sheet.theme.overlay
              Text {
                id: rateTip
                anchors.centerIn: parent
                text: sheet.rates && sheet.rates.age ? "rates " + sheet.rates.age : "rates may be stale"
                color: sheet.theme.text
                font.family: sheet.theme.uiFamily
                font.pixelSize: sheet.theme.barTextSize
                textFormat: Text.PlainText
              }
            }
          }

          Text {
            id: valueText
            anchors.right: parent.right
            anchors.rightMargin: sheet.theme.resultPadX
            anchors.top: parent.top
            height: sheet.rowHeight
            topPadding: sheet.lineInset
            lineHeight: sheet.rowHeight
            lineHeightMode: Text.FixedHeight
            width: Math.min(implicitWidth, sheet.resultWidth - sheet.theme.resultPadX * 2 - (rateTag.visible ? rateTag.width + Style.space(6) : 0))
            // The engine groups thousands with a thin space, which JetBrains
            // Mono draws under 2px wide; a monospace cell reads as the gap.
            text: row.modelData.display.replace(sheet.thinSpaces, " ")
            color: row.valueColor
            font.family: sheet.theme.monoFamily
            // Error messages are words, not numbers, and need the room.
            font.pixelSize: row.isError ? sheet.theme.textSize - 3 : sheet.theme.textSize
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: row.hasValue
            hoverEnabled: row.hasValue
            cursorShape: row.hasValue ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: sheet.copyLine(row.index)
          }
        }
      }
    }
  }

  // Copied pill, bottom-right: a check in ok, the value, then `copied`.
  Rectangle {
    visible: sheet.copiedLine >= 0
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(14)
    width: pillRow.implicitWidth + Style.space(24)
    height: Style.space(30)
    radius: height / 2
    color: sheet.theme.overlay

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(8)
      Text {
        text: "✓"
        color: sheet.theme.ok
        font.family: sheet.theme.uiFamily
        font.pixelSize: sheet.theme.barTextSize + 2
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
      }
      Text {
        text: sheet.copiedValue
        color: sheet.theme.text
        font.family: sheet.theme.monoFamily
        font.pixelSize: sheet.theme.barTextSize + 2
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
      }
      Text {
        text: "copied"
        color: sheet.theme.muted
        font.family: sheet.theme.uiFamily
        font.pixelSize: sheet.theme.barTextSize + 2
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
      }
    }
  }
}
