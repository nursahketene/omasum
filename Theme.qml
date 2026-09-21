import QtQuick
import qs.Commons
import "colour.js" as Colour

// The eleven tokens that carry the entire surface. Nothing in the app names
// a colour; everything reads one of these. They bind to the shell's Color and
// Style singletons, so a theme switch repaints the sheet through property
// bindings with no code of ours running.
//
// The singletons expose five palette colours (foreground, background, accent,
// urgent, muted) plus per-surface roles. accent2, ok and warn have no source
// there, so they are derived in OKLCH; surface, overlay and border are blends
// of text over base. Every foreground token then passes the contrast guard.
QtObject {
  id: theme

  // ------------------------------------------------------------ raw inputs
  // The [menu] roles are what the shell's other summoned surfaces use, so the
  // calculator tracks them when a theme redefines the role.
  readonly property string rawBase: hex(Color.menu.background)
  readonly property string rawText: hex(Color.menu.text)
  readonly property string rawMuted: hex(Color.muted)
  readonly property string rawAccent: hex(Color.accent)
  readonly property string rawUrgent: hex(Color.urgent)
  readonly property string rawForeground: hex(Color.foreground)

  readonly property bool light: Colour.isLight(rawBase)

  // ------------------------------------------------------------ derived
  readonly property string derivedAccent2: Colour.deriveAccent2(rawAccent, [rawUrgent, rawForeground, rawMuted], [rawUrgent])
  readonly property string derivedOk: Colour.deriveHue(rawAccent, [145, 200, 250], [rawAccent, derivedAccent2, rawUrgent])
  readonly property string derivedWarn: Colour.deriveHue(rawAccent, [85, 60, 110], [rawAccent, derivedAccent2, rawUrgent])

  // ------------------------------------------------------------ tokens
  readonly property color base: rawBase
  readonly property color surface: Colour.mix(rawBase, rawText, light ? 0.05 : 0.06)
  readonly property color overlay: Colour.mix(rawBase, rawText, light ? 0.10 : 0.12)
  readonly property color border: Colour.mix(rawBase, rawText, 0.16)
  readonly property color text: Colour.ensureContrast(rawText, rawBase, 4.5)
  readonly property color muted: Colour.ensureContrast(rawMuted, rawBase, 4.5)
  readonly property color accent: Colour.ensureContrast(rawAccent, rawBase, 4.5)
  readonly property color accent2: Colour.ensureContrast(derivedAccent2, rawBase, 4.5)
  readonly property color ok: Colour.ensureContrast(derivedOk, rawBase, 4.5)
  readonly property color warn: Colour.ensureContrast(derivedWarn, rawBase, 4.5)
  readonly property color err: Colour.ensureContrast(rawUrgent, rawBase, 4.5)

  // Selection tints the coloured text underneath rather than hiding it.
  readonly property color selection: Qt.rgba(accent.r, accent.g, accent.b, 0.3)

  // Engine colouring classes -> token colours, as strings for the markup.
  readonly property var palette: ({
    number: hex(text),
    op: hex(muted),
    unit: hex(accent),
    keyword: hex(accent),
    func: hex(accent),
    "const": hex(accent),
    name: hex(accent2),
    unknown: hex(err),
    comment: hex(muted),
    text: hex(text)
  })

  // ------------------------------------------------------------ metrics
  // The handover's numbers, scaled the way the rest of the shell scales so
  // a larger [font] base-size grows the sheet too. Identity at the default.
  readonly property int windowWidth: Style.space(820)
  readonly property int windowHeight: Style.space(600)
  readonly property int barHeight: Style.space(33)
  readonly property int rowHeight: Style.space(30)
  readonly property int spacer: Style.space(12)
  readonly property int resultWidth: Style.space(210)
  readonly property int padX: Style.space(18)
  readonly property int resultPadX: Style.space(15)
  readonly property int textSize: Style.fontPx(17 / 12)
  readonly property int barTextSize: Style.fontPx(11 / 12)
  // Corner rounding is the system's call: Style.cornerRadius mirrors
  // Hyprland's decoration:rounding, zero included.
  readonly property int radius: Style.cornerRadius
  readonly property int borderWidth: Math.max(1, Style.space(2))

  readonly property string monoFamily: Style.font.family
  readonly property string uiFamily: Style.font.family

  function hex(c) {
    var q = Qt.color(c)
    return Qt.rgba(q.r, q.g, q.b, 1).toString()
  }
}
