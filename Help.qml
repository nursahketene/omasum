import QtQuick
import qs.Commons

// The in-app syntax reference, opened from `? syntax` in the top bar. One
// scrollable page: a section title, then example lines with their results,
// the way they would appear on the sheet.
Item {
  id: help

  required property var theme

  readonly property var sections: [
    { title: "Arithmetic", note: "Each line is an expression. The result appears on the right and updates as you type.", rows: [
      ["2 + 3 * (4 - 1)^2", "29"],
      ["3(4+1)", "15"],
      ["2pi", "6.2832"],
      ["1_000_000 / 7", "142 857.14"],
      ["10 % 3", "1"],
      ["sqrt(2) * 10", "14.1421"]
    ]},
    { title: "Names", note: "name = value binds a name for every line below it. ans and last hold the previous result.", rows: [
      ["rent = 1450", "1 450"],
      ["utils = 190", "190"],
      ["total = rent + utils", "1 640"],
      ["total * 12", "19 680"],
      ["ans / 4", "4 920"]
    ]},
    { title: "Comments", note: "Everything after # is a note, at the start of a line or after an expression.", rows: [
      ["# groceries", ""],
      ["rate = 65 eur   # agreed 12 Feb", "65 EUR"]
    ]},
    { title: "Units", note: "A unit tags a value; to, in, into or as converts it. Plurals and long names work.", rows: [
      ["20 km to miles", "12.4274 mi"],
      ["5 in to cm", "12.7 cm"],
      ["92 f to c", "33.3333 °C"],
      ["90 min in h", "1.5 h"],
      ["2.5 GB to MiB", "2 384.19 MiB"],
      ["2 km + 300 m", "2.3 km"],
      ["$120 in eur", "rates from the ECB"]
    ]},
    { title: "Percentages", note: "", rows: [
      ["18% of 240", "43.2"],
      ["240 + 18%", "283.2"],
      ["1450 - 7%", "1 348.5"],
      ["84 as % of 400", "21 %"]
    ]},
    { title: "Bases", note: "0x and 0b prefixes read hex and binary; to hex, bin, oct or dec writes them.", rows: [
      ["0xff + 1", "256"],
      ["255 to hex", "0xFF"],
      ["12 to bin", "0b1100"]
    ]},
    { title: "Functions", note: "sqrt cbrt abs round floor ceil exp ln log log2 sign sin cos tan asin acos atan min max hypot pow — trig in radians. Constants pi, e, tau, phi.", rows: [] },
    { title: "Keys", note: "", rows: [
      ["Enter", "new line"],
      ["Escape", "hide the sheet, keep everything"],
      ["Ctrl+?", "this reference"],
      ["Ctrl+Z", "undo, including clean sheet"],
      ["click a result", "copy the bare number"]
    ]}
  ]

  Flickable {
    id: flick
    anchors.fill: parent
    contentHeight: column.implicitHeight + theme.spacer * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    MouseArea {
      anchors.fill: parent
      onWheel: function(wheel) {
        var max = Math.max(0, flick.contentHeight - flick.height)
        var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y
        flick.contentY = Math.max(0, Math.min(max, flick.contentY - delta / 120 * theme.rowHeight * 2))
        wheel.accepted = true
      }
    }

    Column {
      id: column
      x: theme.padX
      y: theme.spacer
      width: parent.width - theme.padX * 2
      spacing: Style.space(18)

      Repeater {
        model: help.sections

        delegate: Column {
          required property var modelData
          width: column.width
          spacing: Style.space(4)

          Text {
            text: modelData.title
            color: theme.accent
            font.family: theme.uiFamily
            font.pixelSize: theme.barTextSize + 1
            font.bold: true
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1
            textFormat: Text.PlainText
          }

          Text {
            visible: modelData.note !== ""
            width: parent.width
            text: modelData.note
            color: theme.muted
            font.family: theme.uiFamily
            font.pixelSize: theme.barTextSize + 1
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          Item { width: 1; height: Style.space(4); visible: modelData.rows.length > 0 }

          Repeater {
            model: modelData.rows

            delegate: Item {
              required property var modelData
              width: column.width
              height: theme.rowHeight - Style.space(6)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: modelData[0]
                color: theme.text
                font.family: theme.monoFamily
                font.pixelSize: theme.textSize - 2
                textFormat: Text.PlainText
              }
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: modelData[1]
                color: theme.muted
                font.family: theme.monoFamily
                font.pixelSize: theme.textSize - 2
                textFormat: Text.PlainText
              }
            }
          }
        }
      }
    }
  }
}
