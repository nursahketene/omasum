// Colour math for Theme.qml: sRGB <-> OKLCH, WCAG contrast, the derived
// accent2 and the contrast guard. Pure JavaScript, no QML imports, so the
// derivations run under `node --test` as well as inside the shell. Colours
// cross this boundary as "#rrggbb" strings.

function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x }

function hexToRgb(hex) {
  var s = String(hex || "").replace(/^#/, "")
  // Qt spells a colour with alpha as #aarrggbb.
  if (s.length === 8) s = s.slice(2)
  if (s.length === 3) s = s.charAt(0) + s.charAt(0) + s.charAt(1) + s.charAt(1) + s.charAt(2) + s.charAt(2)
  if (!/^[0-9a-fA-F]{6}$/.test(s)) return [0, 0, 0]
  return [parseInt(s.slice(0, 2), 16) / 255, parseInt(s.slice(2, 4), 16) / 255, parseInt(s.slice(4, 6), 16) / 255]
}

function rgbToHex(rgb) {
  var out = "#"
  for (var i = 0; i < 3; i++) {
    var v = Math.round(clamp01(rgb[i]) * 255)
    out += (v < 16 ? "0" : "") + v.toString(16)
  }
  return out
}

function srgbToLinear(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
function linearToSrgb(c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055 }

// Björn Ottosson's Oklab. Input sRGB 0..1, output [L, a, b].
function rgbToOklab(rgb) {
  var r = srgbToLinear(rgb[0]), g = srgbToLinear(rgb[1]), b = srgbToLinear(rgb[2])
  var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  var m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  ]
}

function oklabToRgb(lab) {
  var l_ = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2]
  var m_ = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2]
  var s_ = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2]
  var l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
  return [
    linearToSrgb(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
  ]
}

// [L, C, h] with h in degrees.
function hexToOklch(hex) {
  var lab = rgbToOklab(hexToRgb(hex))
  var c = Math.sqrt(lab[1] * lab[1] + lab[2] * lab[2])
  var h = Math.atan2(lab[2], lab[1]) * 180 / Math.PI
  if (h < 0) h += 360
  return [lab[0], c, h]
}

// Converts back, pulling chroma in until the colour fits in sRGB so a
// rotated hue never clips to a different-looking colour.
function oklchToHex(lch) {
  var L = clamp01(lch[0]), C = Math.max(0, lch[1]), h = lch[2] * Math.PI / 180
  for (var i = 0; i < 12; i++) {
    var rgb = oklabToRgb([L, C * Math.cos(h), C * Math.sin(h)])
    var inside = true
    for (var k = 0; k < 3; k++) if (rgb[k] < -0.002 || rgb[k] > 1.002) inside = false
    if (inside) return rgbToHex(rgb)
    C *= 0.85
  }
  return rgbToHex(oklabToRgb([L, 0, 0]))
}

function luminance(hex) {
  var rgb = hexToRgb(hex)
  return 0.2126 * srgbToLinear(rgb[0]) + 0.7152 * srgbToLinear(rgb[1]) + 0.0722 * srgbToLinear(rgb[2])
}

// WCAG contrast ratio, 1..21.
function contrast(a, b) {
  var la = luminance(a), lb = luminance(b)
  var hi = Math.max(la, lb), lo = Math.min(la, lb)
  return (hi + 0.05) / (lo + 0.05)
}

function isLight(hex) { return hexToOklch(hex)[0] > 0.6 }

function hueDistance(a, b) {
  var d = Math.abs(a - b) % 360
  return d > 180 ? 360 - d : d
}

// Walks a foreground's OKLCH lightness away from `background` until it
// reaches `ratio` against it. Direction comes from whether the background is
// light. Returns the input unchanged when it already passes.
function ensureContrast(fg, bg, ratio) {
  var target = ratio || 4.5
  if (contrast(fg, bg) >= target) return fg
  var lch = hexToOklch(fg)
  var step = isLight(bg) ? -0.02 : 0.02
  var out = fg
  for (var i = 0; i < 60; i++) {
    lch[0] += step
    if (lch[0] <= 0 || lch[0] >= 1) break
    out = oklchToHex(lch)
    if (contrast(out, bg) >= target) return out
  }
  return isLight(bg) ? "#000000" : "#ffffff"
}

// accent2 has to be derived, because no theme declares a second accent. From
// the named palette colours, drop any within about 40 degrees of hue of
// accent (or of anything in `avoid`, which is `err`: a name and an unknown
// word must never share a colour) and any too grey to read as a hue, then
// pick the one closest to accent in lightness. If none survive, rotate
// accent in OKLCH keeping its chroma and lightness — 120 degrees first, then
// the other rotations, whichever clears every colour to avoid.
function deriveAccent2(accent, candidates, avoid) {
  var a = hexToOklch(accent)
  var away = [accent].concat(avoid || [])
  function clear(hue) {
    for (var k = 0; k < away.length; k++) if (hueDistance(hue, hexToOklch(away[k])[2]) < 40) return false
    return true
  }
  var best = null
  var bestDist = Infinity
  var list = candidates || []
  for (var i = 0; i < list.length; i++) {
    var c = hexToOklch(list[i])
    if (c[1] < 0.05) continue
    if (!clear(c[2])) continue
    var dist = Math.abs(c[0] - a[0])
    if (dist < bestDist) { bestDist = dist; best = list[i] }
  }
  if (best) return best
  var turns = [120, -120, 180, 90, -90, 60, -60]
  var hue = (a[2] + 120) % 360
  for (var t = 0; t < turns.length; t++) {
    var h = (a[2] + turns[t] + 360) % 360
    if (clear(h)) { hue = h; break }
  }
  return oklchToHex([a[0], Math.max(a[1], 0.09), hue])
}

// ok and warn are not exposed by the shell's palette singleton either, so
// they take accent's lightness and chroma at a green and a yellow hue. The
// first hue in `hues` at least 40 degrees from every colour in `avoid` wins,
// so `ok` never reads as accent2.
function deriveHue(accent, hues, avoid) {
  var a = hexToOklch(accent)
  var L = Math.min(0.88, Math.max(0.55, a[0]))
  var list = Array.isArray(hues) ? hues : [hues]
  var hue = list[0]
  for (var i = 0; i < list.length; i++) {
    var clear = true
    for (var j = 0; j < (avoid || []).length; j++) {
      if (hueDistance(list[i], hexToOklch(avoid[j])[2]) < 40) clear = false
    }
    if (clear) { hue = list[i]; break }
  }
  return oklchToHex([L, Math.max(a[1], 0.10), hue])
}

// Opaque blend of `top` over `base`, `t` in 0..1.
function mix(base, top, t) {
  var a = hexToRgb(base), b = hexToRgb(top)
  return rgbToHex([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t])
}

var Colour = {
  hexToOklch: hexToOklch,
  oklchToHex: oklchToHex,
  contrast: contrast,
  isLight: isLight,
  ensureContrast: ensureContrast,
  deriveAccent2: deriveAccent2,
  deriveHue: deriveHue,
  mix: mix
}

if (typeof module !== "undefined" && module.exports) module.exports = Colour
