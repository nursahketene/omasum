// The two theme derivations Theme.qml relies on: accent2 never collides
// with accent, and the contrast guard lifts a weak token to 4.5:1.
const test = require("node:test")
const assert = require("node:assert/strict")
const Colour = require("../colour.js")

test("oklch round-trips", () => {
  for (const hex of ["#f38d70", "#2c2525", "#e6d9db", "#88c0d0", "#000000", "#ffffff"]) {
    const back = Colour.oklchToHex(Colour.hexToOklch(hex))
    const [a, b] = [Colour.hexToOklch(hex), Colour.hexToOklch(back)]
    assert.ok(Math.abs(a[0] - b[0]) < 0.01, `${hex} lightness`)
  }
})

test("contrast: black on white is 21", () => {
  assert.ok(Math.abs(Colour.contrast("#000000", "#ffffff") - 21) < 0.01)
})

test("contrast guard: nord muted on nord background reaches 4.5", () => {
  // Nord's comment colour on its background sits around 4.4:1.
  const fixed = Colour.ensureContrast("#616e88", "#2e3440", 4.5)
  assert.ok(Colour.contrast(fixed, "#2e3440") >= 4.5)
  assert.notEqual(fixed, "#616e88")
})

test("contrast guard: leaves a passing colour alone", () => {
  assert.equal(Colour.ensureContrast("#e6d9db", "#2c2525", 4.5), "#e6d9db")
})

test("contrast guard: darkens on a light theme", () => {
  const fixed = Colour.ensureContrast("#c0c0c0", "#fafafa", 4.5)
  assert.ok(Colour.contrast(fixed, "#fafafa") >= 4.5)
  assert.ok(Colour.hexToOklch(fixed)[0] < Colour.hexToOklch("#c0c0c0")[0])
})

test("accent2: picks a named colour far enough in hue", () => {
  // Blue accent, red urgent: urgent is a valid second accent.
  const out = Colour.deriveAccent2("#88c0d0", ["#bf616a", "#d8dee9", "#4c566a"])
  assert.equal(out, "#bf616a")
})

test("accent2: rotates when every candidate is too close or too grey", () => {
  const out = Colour.deriveAccent2("#f38d70", ["#fd6883", "#e6d9db", "#72696a"])
  const a = Colour.hexToOklch("#f38d70"), b = Colour.hexToOklch(out)
  const d = Math.abs(a[2] - b[2]) % 360
  assert.ok(Math.min(d, 360 - d) > 40, `hue distance ${d}`)
})

test("mix: halfway between black and white is mid grey", () => {
  assert.equal(Colour.mix("#000000", "#ffffff", 0.5), "#808080")
})

test("ok: steps off green when accent2 already took it", () => {
  const accent2 = Colour.deriveAccent2("#f38d70", ["#fd6883"])
  const ok = Colour.deriveHue("#f38d70", [145, 200, 250], [accent2])
  const d = Math.abs(Colour.hexToOklch(ok)[2] - Colour.hexToOklch(accent2)[2]) % 360
  assert.ok(Math.min(d, 360 - d) >= 30, `hue distance ${d}`)
})

test("accent2: never lands on err", () => {
  // Catppuccin Latte: blue accent, red urgent. The 120° rotation of blue is
  // orange-red, so both the candidate and the first rotation must be skipped.
  const out = Colour.deriveAccent2("#1e66f5", ["#d20f39", "#4c4f69", "#9ca0b0"], ["#d20f39"])
  const h = Colour.hexToOklch(out)[2]
  for (const other of ["#1e66f5", "#d20f39"]) {
    const d = Math.abs(h - Colour.hexToOklch(other)[2]) % 360
    assert.ok(Math.min(d, 360 - d) >= 40, `${out} too close to ${other}`)
  }
})
