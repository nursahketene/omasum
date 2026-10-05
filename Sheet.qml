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
// <div style="line-height:30px; white-space:pre-wrap"> block, and the
// painted layer is the same markup in the same block, so both wrap at the
// same places. Long lines wrap at the result column; a line's rows are
// read back from the editor's layout into `lineTops`. Enter inherits the block
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
  // What Tab would complete at the cursor, or null: `@n` (kind "line",
  // swapped for line n's value) or a partly typed name (kind "name", the
  // rest of the name appended). Fields come from Engine.completeReference
  // and Engine.completeName, plus { kind, index, lineStart, ghostX, ghostY }.
  property var pending: null
  property string copiedValue: ""

  signal edited()
  signal copied(string value)
  // Tab leaves the editor for the bar controls; the panel decides where.
  signal tabPressed(bool backwards)

  readonly property int rowHeight: theme.rowHeight
  readonly property int spacer: theme.spacer
  readonly property int resultWidth: theme.resultWidth
  readonly property int editorWidth: width - resultWidth

  // Line numbers: a fixed gutter left of the editor, wide enough for the
  // last line's number and never narrower than two digits, so the text
  // does not shift until line 100.
  readonly property int digits: Math.max(2, String(lineCount).length)
  readonly property int gutterPadX: Style.space(12)
  readonly property int gutterWidth: gutterPadX + Math.ceil(gutterMetrics.advanceWidth("0") * digits)
  readonly property int cursorLine: text.slice(0, editor.cursorPosition).split("\n").length - 1

  // Wrapped layout: the top of each line's first row, read from the
  // editor after every change, and the number of rows in all.
  property var lineTops: [0]
  readonly property int visualRows: Math.max(1, editor.lineCount)
  function rowTop(index) {
    var t = lineTops[index]
    return t === undefined ? index * rowHeight : t
  }
  function rowSpan(index) {
    var next = index + 1 < lineTops.length ? lineTops[index + 1] : visualRows * rowHeight
    return Math.max(rowHeight, next - rowTop(index))
  }
  // The editor reports a position at its caret's top, which sits low in
  // the row; snap it to the row it is in.
  function rowAt(position) {
    return Math.floor(editor.positionToRectangle(position).y / rowHeight) * rowHeight
  }
  function updateLayout() {
    var lines = text.split("\n")
    var tops = []
    var pos = 0
    for (var i = 0; i < lines.length; i++) {
      tops.push(rowAt(pos))
      pos += lines[i].length + 1
    }
    lineTops = tops
  }

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

  FontMetrics {
    id: gutterMetrics
    font.family: sheet.theme.monoFamily
    font.pixelSize: sheet.theme.barTextSize
  }
  // The gutter number sits on the text's baseline, lifted a pixel: a short
  // digit beside tall ones reads low when their feet match exactly.
  readonly property real gutterInset: lineInset + metrics.ascent - gutterMetrics.ascent - Style.space(1)

  function focusEditor() {
    editor.forceActiveFocus()
  }

  // ------------------------------------------------------------ document

  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function lineHtml(html) {
    return '<div style="line-height:' + rowHeight + 'px; white-space:pre-wrap">' + html + "</div>"
  }

  // One block, lines separated by <br>: Qt's importer drops an empty <div>,
  // and a <br> line separator carries the block's line-height just the same.
  // Both separators come back as "\n" from plainText().
  function toHtml(plain) {
    var lines = String(plain).split("\n")
    for (var i = 0; i < lines.length; i++) lines[i] = escapeHtml(lines[i])
    return lineHtml(lines.join("<br>"))
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
    var s = String(value || "").replace(/\r\n?/g, "\n").replace(/\u00a0/g, " ")
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
    Qt.callLater(updateLayout)
    Qt.callLater(updatePending)
  }

  // ------------------------------------------------------------ references

  // Runs after both the text and the cursor have settled, so the line and
  // column are read from the same state.
  function updatePending() {
    var p = null
    if (editor.selectionStart === editor.selectionEnd) {
      var pos = editor.cursorPosition
      var lineStart = text.lastIndexOf("\n", pos - 1) + 1
      var index = text.slice(0, lineStart).split("\n").length - 1
      p = Engine.completeReference(result, index, pos - lineStart, rates)
      if (p) p.kind = "line"
      else {
        p = Engine.completeName(result, index, pos - lineStart)
        if (p) p.kind = "name"
      }
      if (p) {
        p.index = index
        p.lineStart = lineStart
        var end = lineStart + result.lines[index].raw.length
        p.ghostX = editor.positionToRectangle(end).x
        p.ghostY = rowAt(end)
      }
    }
    pending = p
  }

  // Swaps `@n` for line n's value, or a partly typed name for the whole
  // name as defined, case included. The remove and the insert are two steps
  // on the editor's undo stack; `referenceUndo` lets one Ctrl+Z take both
  // back while nothing else has been typed since.
  property bool referenceUndo: false
  function acceptReference() {
    var p = pending
    if (!p || !p.text) return
    var from = p.lineStart + p.start
    editor.remove(from, p.lineStart + p.end)
    insertPlain(from, p.text)
    editor.cursorPosition = from + p.text.length
    referenceUndo = true
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
  }

  // ------------------------------------------------------------ layout

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: Math.max(height, sheet.spacer + sheet.visualRows * sheet.rowHeight + sheet.spacer)
    boundsBehavior: Flickable.StopAtBounds
    interactive: false

    // Click below the last line puts the cursor at the end of the sheet.
    // Wheel scrolls; dragging is left to the editor for selection.
    MouseArea {
      anchors.fill: parent
      onClicked: function(mouse) {
        if (mouse.y < sheet.spacer + sheet.visualRows * sheet.rowHeight) return
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
      y: sheet.spacer + sheet.rowTop(sheet.copiedLine)
      width: flick.width
      height: sheet.rowSpan(sheet.copiedLine)
      color: sheet.theme.surface
    }

    // Gutter: small numbers in a faded muted, sitting on the text's baseline,
    // so they read as labels rather than part of the line. The
    // cursor's line is full muted. Fixed while long lines slide sideways
    // under the editor's clip.
    Item {
      x: 0
      y: sheet.spacer
      width: sheet.gutterWidth
      visible: !sheet.empty

      Repeater {
        model: sheet.lineCount
        delegate: Text {
          required property int index
          readonly property bool current: index === sheet.cursorLine && editor.activeFocus
          y: sheet.rowTop(index)
          width: sheet.gutterWidth
          topPadding: sheet.gutterInset
          horizontalAlignment: Text.AlignRight
          text: index + 1
          color: sheet.theme.muted
          opacity: current ? 1 : 0.55
          font.family: sheet.theme.monoFamily
          font.pixelSize: sheet.theme.barTextSize
          textFormat: Text.PlainText
        }
      }
    }

    Item {
      id: editorColumn
      x: sheet.gutterWidth
      y: sheet.spacer
      width: sheet.editorWidth - sheet.gutterWidth
      height: sheet.visualRows * sheet.rowHeight
      clip: true

      Item {
        width: editorColumn.width
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
          textFormat: Text.RichText
          text: sheet.lineHtml(sheet.markup)
          color: sheet.theme.text
          font.family: sheet.theme.monoFamily
          font.pixelSize: sheet.theme.textSize
          wrapMode: Text.Wrap
        }

        // Preview of what Tab pastes for `@n`, after the end of its line.
        Text {
          visible: !!sheet.pending
          x: sheet.pending ? sheet.pending.ghostX + Style.space(12) : 0
          y: sheet.pending ? sheet.pending.ghostY : 0
          height: sheet.rowHeight
          topPadding: sheet.lineInset
          lineHeight: sheet.rowHeight
          lineHeightMode: Text.FixedHeight
          // A name shows its current value and how many others match.
          text: !sheet.pending ? ""
            : sheet.pending.kind === "name"
              ? "⇥ " + sheet.pending.name + "  " + sheet.pending.value.replace(sheet.thinSpaces, " ")
                + (sheet.pending.more > 0 ? "  +" + sheet.pending.more : "")
            : sheet.pending.text ? "⇥ " + sheet.pending.text
            : sheet.pending.error
          color: sheet.theme.muted
          font.family: sheet.theme.monoFamily
          font.pixelSize: sheet.theme.textSize
          font.italic: !!sheet.pending && !sheet.pending.text
          textFormat: Text.PlainText
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
          wrapMode: TextEdit.Wrap
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
          onWidthChanged: Qt.callLater(sheet.updateLayout)
          onCursorPositionChanged: Qt.callLater(sheet.updatePending)
          onSelectionStartChanged: Qt.callLater(sheet.updatePending)

          Keys.onPressed: function(event) {
            var ctrl = event.modifiers & Qt.ControlModifier
            var shift = event.modifiers & Qt.ShiftModifier
            // A bare modifier is not an edit; Ctrl on its way to Ctrl+Z
            // must not end the undo pairing.
            if (event.key === Qt.Key_Control || event.key === Qt.Key_Shift
                || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) return
            var paired = sheet.referenceUndo
            sheet.referenceUndo = false
            // Tab completes what the preview offers: `@n` becomes line n's
            // value, a partly typed name its full name. An `@n` with no
            // valid value does nothing rather than leave the editor.
            if (event.key === Qt.Key_Tab && !shift && sheet.pending) {
              sheet.acceptReference()
              event.accepted = true
              return
            }
            if (ctrl && !shift && event.key === Qt.Key_Z && paired) {
              editor.undo()
              editor.undo()
              event.accepted = true
              return
            }
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
          // A line waiting on Tab for `@n` shows no lex error meanwhile.
          readonly property bool isError: modelData.kind === "error"
            && !(sheet.pending && sheet.pending.index === index)
          readonly property bool staleRate: hasValue && modelData.usedRate && !!sheet.rates && !!sheet.rates.stale
          readonly property color valueColor: isError ? sheet.theme.err
            : modelData.kind === "assign" ? sheet.theme.ok : sheet.theme.text

          y: sheet.rowTop(index)
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
            text: row.modelData.kind === "error" && !row.isError ? ""
              : row.modelData.display.replace(sheet.thinSpaces, " ")
            color: row.valueColor
            font.family: sheet.theme.monoFamily
            // Error messages are words, not numbers, and need the room.
            font.pixelSize: row.isError ? sheet.theme.textSize - 3 : sheet.theme.textSize
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
          }

          // Hovering a cut-off result or error shows the whole text.
          Rectangle {
            visible: valueText.truncated && rowMouse.containsMouse
            anchors.bottom: valueText.top
            anchors.bottomMargin: Style.space(4)
            anchors.right: valueText.right
            width: fullTip.implicitWidth + Style.space(16)
            height: fullTip.implicitHeight + Style.space(8)
            radius: Style.space(4)
            color: sheet.theme.overlay
            Text {
              id: fullTip
              anchors.centerIn: parent
              text: valueText.text
              color: row.valueColor
              font.family: sheet.theme.monoFamily
              font.pixelSize: sheet.theme.barTextSize
              textFormat: Text.PlainText
            }
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: row.hasValue ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (row.hasValue) sheet.copyLine(row.index)
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
