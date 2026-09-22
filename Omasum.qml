import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Omasum panel: the window, its bars, the help screen, persistence and the
// currency rates. The sheet itself lives in Sheet.qml and every parsing,
// unit and formatting decision in engine.js.
//
// Summoned over shell IPC: `omarchy-shell shell toggle dev.nur.omasum`.
// The host calls open(payload) and close(); `opened` tells it our state.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool helpOpen: false

  readonly property string pluginId: (manifest && manifest.id) ? manifest.id : "dev.nur.omasum"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omasum"
  readonly property string cacheDir: home + "/.cache/omasum"
  readonly property string sheetPath: stateDir + "/sheet.calc"
  readonly property string ratesPath: cacheDir + "/rates.json"
  readonly property string ratesUrl: "https://api.frankfurter.dev/v1/latest?base=EUR"

  Theme { id: theme }

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    opened = true
    helpOpen = false
    refreshRatesIfStale()
    Qt.callLater(function() { sheet.focusEditor() })
  }

  function close() {
    opened = false
    helpOpen = false
    flushSave()
  }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  // ------------------------------------------------------------ persistence
  //
  // One sheet, autosaved, plain UTF-8, exactly what the buffer holds. Written
  // on a 400ms debounce after the last keystroke and again when the panel
  // hides. Atomic writes so an interrupted write cannot truncate the sheet.

  property bool sheetLoaded: false
  property bool sheetReadFailed: false
  property bool loadingSheet: false
  property bool saveDirty: false

  Process {
    id: mkdirs
    command: ["mkdir", "-p", root.stateDir, root.cacheDir]
    running: true
  }

  FileView {
    id: sheetFile
    path: root.sheetPath
    printErrors: false
    atomicWrites: true
    onLoaded: {
      root.loadingSheet = true
      sheet.setText(text())
      root.loadingSheet = false
      root.sheetLoaded = true
    }
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) {
        root.sheetLoaded = true
        return
      }
      // Never show a file error in the UI, never overwrite a file we could
      // not read.
      console.warn("omasum: could not read " + root.sheetPath + ": " + FileViewError.toString(error))
      root.sheetReadFailed = true
      root.sheetLoaded = true
    }
    onSaveFailed: function(error) {
      console.warn("omasum: could not write " + root.sheetPath + ": " + FileViewError.toString(error))
    }
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: root.writeSheet()
  }

  function scheduleSave() {
    if (loadingSheet) return
    saveDirty = true
    saveTimer.restart()
  }

  function writeSheet() {
    saveTimer.stop()
    if (!saveDirty || !sheetLoaded || sheetReadFailed) return
    saveDirty = false
    sheetFile.setText(sheet.text)
  }

  function flushSave() {
    if (saveDirty) writeSheet()
  }

  function cleanSheet() {
    sheet.clear()
    saveDirty = true
    writeSheet()
  }

  // ------------------------------------------------------------ rates
  //
  // Euro-based daily rates from the ECB via Frankfurter. Cached to
  // ~/.cache/omasum/rates.json; refreshed when older than 24 hours on load
  // and on open, never on a keystroke. Fetched by a curl subprocess — a
  // blocking fetch in the shell process would freeze the bar and every
  // menu, and curl gives a hard byte limit that XMLHttpRequest does not.

  property var rates: null
  property bool fetchingRates: false
  property double lastFetchAttempt: 0
  readonly property int staleAfterMs: 24 * 3600 * 1000

  FileView {
    id: ratesFile
    path: root.ratesPath
    printErrors: false
    atomicWrites: true
    onLoaded: {
      root.applyRatesCache(text())
      root.refreshRatesIfStale()
    }
    onLoadFailed: root.refreshRatesIfStale()
  }

  function describeAge(ms) {
    var hours = Math.floor(ms / 3600000)
    if (hours < 1) return "from the last hour"
    if (hours < 24) return hours + (hours === 1 ? " hour old" : " hours old")
    var days = Math.floor(hours / 24)
    return days + (days === 1 ? " day old" : " days old")
  }

  function applyRatesCache(raw) {
    try {
      var data = JSON.parse(raw)
      if (!data || typeof data.rates !== "object") return
      var fetched = Date.parse(data.fetched || "")
      var age = isFinite(fetched) ? Date.now() - fetched : Infinity
      root.rates = {
        base: data.base || "EUR",
        date: data.date || "",
        fetched: data.fetched || "",
        rates: data.rates,
        stale: age > root.staleAfterMs,
        age: isFinite(age) ? root.describeAge(age) : "of unknown age"
      }
    } catch (e) {
      console.warn("omasum: ignoring unreadable rates cache")
    }
  }

  function refreshRatesIfStale() {
    if (rates && !rates.stale) return
    if (fetchingRates) return
    // Offline, a failed fetch would otherwise retry on every open.
    if (Date.now() - lastFetchAttempt < 10 * 60 * 1000) return
    fetchRates()
  }

  // The response is capped at 64 KiB on the producer side: curl aborts the
  // transfer past --max-filesize whether or not the server sent a truthful
  // Content-Length, so a faulty or hostile endpoint cannot stream an
  // unbounded body into the shell process. A real response is under 1 KiB.
  // The collector is checked against the same cap before parsing, and only
  // a complete, successful, in-limit body is parsed and cached.
  readonly property int ratesMaxBytes: 65536

  Process {
    id: ratesFetch
    command: [
      "curl", "--silent", "--show-error", "--fail",
      "--proto", "=https",
      "--max-time", "15", "--max-filesize", String(root.ratesMaxBytes),
      root.ratesUrl
    ]
    stdout: StdioCollector {
      id: ratesOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: ratesErr
      waitForEnd: true
    }
    onExited: function(code) {
      root.fetchingRates = false
      if (code !== 0) {
        var why = String(ratesErr.text || "").replace(/\s+$/, "")
        console.warn("omasum: rates fetch failed (curl exit " + code + ")" + (why ? ": " + why : ""))
        return
      }
      root.applyFetchedRates(ratesOut.text)
    }
  }

  function fetchRates() {
    if (ratesFetch.running) return
    fetchingRates = true
    lastFetchAttempt = Date.now()
    ratesFetch.running = true
  }

  function applyFetchedRates(body) {
    var raw = String(body || "")
    if (raw.length === 0 || raw.length > ratesMaxBytes) {
      console.warn("omasum: rates response rejected (" + raw.length + " bytes)")
      return
    }
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      console.warn("omasum: rates response was not JSON")
      return
    }
    if (!data || typeof data.rates !== "object" || data.rates === null) return
    // Keep only what the engine reads: ISO code -> finite positive number.
    var rates = {}
    var count = 0
    for (var code in data.rates) {
      var v = data.rates[code]
      if (/^[A-Z]{3}$/.test(code) && typeof v === "number" && isFinite(v) && v > 0) {
        rates[code] = v
        count++
      }
    }
    if (count === 0) return
    rates.EUR = 1
    var cache = {
      fetched: new Date().toISOString(),
      base: "EUR",
      date: typeof data.date === "string" ? data.date.slice(0, 10) : "",
      rates: rates
    }
    ratesFile.setText(JSON.stringify(cache, null, 2) + "\n")
    root.rates = {
      base: cache.base, date: cache.date, fetched: cache.fetched,
      rates: cache.rates, stale: false, age: "from today"
    }
  }

  // ------------------------------------------------------------ window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omasum"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    // Escape hides the window and never clears the sheet; with the help
    // screen up it goes back to the sheet first.
    Item {
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.helpOpen) { root.helpOpen = false; sheet.focusEditor() }
          else root.dismiss()
          event.accepted = true
          return
        }
        // Ctrl+? toggles the syntax help; Ctrl+/ too, for layouts where
        // ? is not Shift+/.
        var ctrl = event.modifiers & Qt.ControlModifier
        if (ctrl && (event.key === Qt.Key_Question || event.key === Qt.Key_Slash)) {
          root.toggleHelp()
          event.accepted = true
        }
      }

      MultiEffect {
        source: card
        anchors.fill: card
        shadowEnabled: true
        shadowBlur: 1.0
        shadowOpacity: 0.55
        shadowVerticalOffset: Style.space(10)
        shadowColor: "#000000"
      }

      Rectangle {
        id: card
        width: theme.windowWidth
        height: theme.windowHeight
        anchors.centerIn: parent
        radius: theme.radius
        color: theme.base
        border.color: theme.accent
        border.width: theme.borderWidth
        clip: true

        MouseArea { anchors.fill: parent; onClicked: {} }

        // ---------------------------------------------------- top bar
        Rectangle {
          id: topBar
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: theme.borderWidth
          height: theme.barHeight
          color: theme.surface
          // Follow the card's rounding on the outer corners so the bar
          // never pokes a square corner through a rounded border.
          topLeftRadius: Math.max(0, theme.radius - theme.borderWidth)
          topRightRadius: Math.max(0, theme.radius - theme.borderWidth)

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: theme.border
          }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: theme.padX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(14)

            BarHint { key: "↵"; label: "new line" }
            BarHint { key: "#"; label: "comment" }
            BarHint { key: ""; label: "click a result to copy" }
            BarHint { key: "ctrl ?"; label: "" }

            Text {
              id: helpLink
              text: root.helpOpen ? "← sheet" : "? syntax"
              color: helpMouse.containsMouse ? theme.text : theme.accent
              font.family: theme.uiFamily
              font.pixelSize: theme.barTextSize
              font.underline: helpMouse.containsMouse
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  root.toggleHelp()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  cleanButton.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  sheet.focusEditor()
                  event.accepted = true
                }
              }
              Rectangle {
                anchors.fill: parent
                anchors.margins: -Style.space(3)
                color: "transparent"
                border.color: theme.accent
                border.width: parent.activeFocus ? 1 : 0
                radius: Style.space(3)
              }
              MouseArea {
                id: helpMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleHelp()
              }
            }
          }

          // Clean sheet: trash glyph, muted, err on hover.
          Item {
            id: cleanButton
            anchors.right: parent.right
            anchors.rightMargin: theme.padX
            anchors.verticalCenter: parent.verticalCenter
            width: cleanRow.implicitWidth
            height: parent.height
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                root.cleanSheet()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab) {
                sheet.focusEditor()
                event.accepted = true
              } else if (event.key === Qt.Key_Backtab) {
                helpLink.forceActiveFocus()
                event.accepted = true
              }
            }
            Rectangle {
              anchors.fill: cleanRow
              anchors.margins: -Style.space(3)
              color: "transparent"
              border.color: theme.err
              border.width: cleanButton.activeFocus ? 1 : 0
              radius: Style.space(3)
            }
            Row {
              id: cleanRow
              anchors.centerIn: parent
              spacing: Style.space(6)
              Text {
                text: "󰩹"
                color: cleanMouse.containsMouse ? theme.err : theme.muted
                font.family: theme.uiFamily
                font.pixelSize: theme.barTextSize + 3
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: "clean sheet"
                color: cleanMouse.containsMouse ? theme.err : theme.muted
                font.family: theme.uiFamily
                font.pixelSize: theme.barTextSize
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            MouseArea {
              id: cleanMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cleanSheet()
            }
          }
        }

        // ---------------------------------------------------- sheet
        Sheet {
          id: sheet
          theme: theme
          rates: root.rates
          visible: !root.helpOpen
          anchors.top: topBar.bottom
          anchors.bottom: bottomBar.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: theme.borderWidth
          anchors.rightMargin: theme.borderWidth
          onEdited: root.scheduleSave()
          onTabPressed: function(backwards) {
            if (backwards) cleanButton.forceActiveFocus()
            else helpLink.forceActiveFocus()
          }
        }

        Help {
          theme: theme
          visible: root.helpOpen
          anchors.fill: sheet
        }

        // ---------------------------------------------------- bottom bar
        Rectangle {
          id: bottomBar
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: theme.borderWidth
          height: theme.barHeight
          color: theme.surface
          bottomLeftRadius: Math.max(0, theme.radius - theme.borderWidth)
          bottomRightRadius: Math.max(0, theme.radius - theme.borderWidth)

          Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: theme.border
          }

          Text {
            id: countText
            anchors.right: parent.right
            anchors.rightMargin: theme.padX
            anchors.verticalCenter: parent.verticalCenter
            text: sheet.empty ? "empty sheet"
              : sheet.lineCount + (sheet.lineCount === 1 ? " line" : " lines") + " · "
                + sheet.resultCount + (sheet.resultCount === 1 ? " result" : " results")
            color: theme.muted
            font.family: theme.uiFamily
            font.pixelSize: theme.barTextSize
            textFormat: Text.PlainText
          }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: theme.padX
            anchors.right: countText.left
            anchors.rightMargin: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            clip: true

            Text {
              text: "in scope"
              color: theme.muted
              font.family: theme.uiFamily
              font.pixelSize: theme.barTextSize
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              visible: sheet.names.length === 0
              text: "nothing yet — write name = value on any line"
              color: theme.muted
              font.family: theme.uiFamily
              font.pixelSize: theme.barTextSize
              font.italic: true
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              visible: sheet.names.length > 0
              text: sheet.names.join("  ")
              color: theme.accent2
              font.family: theme.monoFamily
              font.pixelSize: theme.barTextSize
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }
  }

  function toggleHelp() {
    helpOpen = !helpOpen
    if (!helpOpen) sheet.focusEditor()
  }

  // A key name in `text`, the words around it in `muted`.
  component BarHint: Row {
    property string key: ""
    property string label: ""
    spacing: Style.space(5)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    Text {
      visible: key !== ""
      text: key
      color: theme.text
      font.family: theme.uiFamily
      font.pixelSize: theme.barTextSize
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      visible: label !== ""
      text: label
      color: theme.muted
      font.family: theme.uiFamily
      font.pixelSize: theme.barTextSize
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
