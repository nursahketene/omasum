// Engine test vectors from the handover. One line in, one display string
// out, against an empty scope unless stated. Run with `node --test`.
const test = require("node:test")
const assert = require("node:assert/strict")
const Engine = require("../engine.js")

const T = Engine.THIN_SPACE

function display(input, opts) {
  return Engine.evaluateSheet(input, opts).lines[0].display
}

function sheet(text, opts) {
  return Engine.evaluateSheet(text, opts).lines.map(l => l.display)
}

const vectors = [
  ["2 + 3 * (4 - 1)^2", "29"],
  ["2^-1", "0.5"],
  ["3(4+1)", "15"],
  ["2pi", "6.2832"],
  ["sqrt(2) * 10", "14.1421"],
  ["1_000_000 / 7", `142${T}857.14`],
  ["1,000 + 1", `1${T}001`],
  ["min(1,2)", "1"],
  ["10 % 3", "1"],
  ["0xff + 1", "256"],
  ["0b1010 * 2", "20"],
  ["18% of 240", "43.2"],
  ["240 + 18%", "283.2"],
  ["1450 - 7%", `1${T}348.5`],
  ["84 as % of 400", `21${T}%`],
  ["20 km to miles", `12.4274${T}mi`],
  ["5 in to cm", `12.7${T}cm`],
  ["92 f to c", `33.3333${T}°C`],
  ["100 c to f", `212${T}°F`],
  ["2.5 GB to MiB", `2${T}384.19${T}MiB`],
  ["90 min in h", `1.5${T}h`],
  ["75 kg to lbs", `165.35${T}lb`],
  ["255 to hex", "0xFF"],
  ["12 to bin", "0b1100"],
]

for (const [input, expected] of vectors) {
  test(`display: ${input}`, () => assert.equal(display(input), expected))
}

test("scope: rate = 65 eur / rate", () => {
  assert.deepEqual(sheet("rate = 65 eur\nrate"), [`65${T}EUR`, `65${T}EUR`])
})

test("scope: leg = 18 km / leg * 2 * 21 to miles", () => {
  assert.deepEqual(sheet("leg = 18 km\nleg * 2 * 21 to miles"), [`18${T}km`, `469.76${T}mi`])
})

test("scope: hours * rate keeps the unit", () => {
  assert.equal(sheet("hours = 38\nrate = 65 eur\nhours * rate")[2], `2${T}470${T}EUR`)
})

test("scope: ans carries the previous unit", () => {
  assert.equal(sheet("hours = 38\nrate = 65 eur\nhours * rate\nans / 3")[3], `823.33${T}EUR`)
})

const errors = [
  ["hours * rat", "rat is not defined"],
  ["12 km to kg", "can't convert km to kg"],
  ["12 km to kgg", "kgg is not a unit"],
  ["240 to eur", "no unit to convert from"],
  ["2 +", "unfinished line"],
  ["(2 + 3", "missing )"],
]

for (const [input, message] of errors) {
  test(`error: ${input}`, () => {
    const line = Engine.evaluateSheet(input).lines[0]
    assert.equal(line.kind, "error")
    assert.equal(line.error, message)
  })
}

test("sheet: propagation on edit", () => {
  const a = sheet("rent = 1450\nutils = 190\ntotal = rent + utils\ntotal * 12")
  assert.deepEqual(a, [`1${T}450`, "190", `1${T}640`, `19${T}680`])
  const b = sheet("rent = 1600\nutils = 190\ntotal = rent + utils\ntotal * 12")
  assert.deepEqual(b, [`1${T}600`, "190", `1${T}790`, `21${T}480`])
})

test("sheet: comments", () => {
  const r = Engine.evaluateSheet("# just a note\nrate = 65 eur   # agreed 12 Feb")
  assert.equal(r.lines[0].kind, "blank")
  assert.equal(r.lines[0].error, null)
  assert.equal(r.lines[1].display, `65${T}EUR`)
  assert.equal(r.lines[1].comment, "# agreed 12 Feb")
})

test("sheet: no forward references", () => {
  const r = Engine.evaluateSheet("x * 2\nx = 4")
  assert.equal(r.lines[0].error, "x is not defined")
  assert.equal(r.lines[1].display, "4")
})

test("sheet: one bad line never stops the rest", () => {
  const r = Engine.evaluateSheet("hours = 38\nrate = 65\nhours * rat\nhours * rate")
  assert.deepEqual(r.lines.map(l => l.kind), ["assign", "assign", "error", "value"])
  assert.equal(r.lines[3].display, `2${T}470`)
})

test("plain: bare number for the clipboard", () => {
  const r = Engine.evaluateSheet("27120\n20 km to miles\n84 as % of 400")
  assert.deepEqual(r.lines.map(l => l.plain), ["27120", "12.4274", "21"])
})

test("plain: scientific and non-finite", () => {
  assert.equal(Engine.formatPlain(1e12), "1.0000e12")
  assert.equal(Engine.formatPlain(0.0000001), "1.0000e-7")
  assert.equal(Engine.formatPlain(0), "0")
  assert.equal(Engine.formatPlain(NaN), "—")
  assert.equal(Engine.formatPlain(Infinity), "∞")
  assert.equal(Engine.formatPlain(-Infinity), "-∞")
})

test("bases: negative keeps the sign after the prefix", () => {
  assert.equal(display("-255 to hex"), "0x-FF")
  assert.equal(display("15 to oct"), "0o17")
  assert.equal(display("0xff to dec"), "255")
})

test("currency: symbols rewrite to trailing unit words", () => {
  const rates = { base: "EUR", rates: { USD: 1.25, GBP: 0.8 } }
  assert.equal(display("$120 in eur", { rates }), `96${T}EUR`)
  assert.equal(display("€10 to usd", { rates }), `12.5${T}USD`)
  assert.equal(display("£8 to eur", { rates }), `10${T}EUR`)
})

test("currency: rates unavailable without a cache", () => {
  const line = Engine.evaluateSheet("120 usd to eur").lines[0]
  assert.equal(line.error, "rates unavailable")
  assert.equal(display("65 eur"), `65${T}EUR`)
  assert.equal(display("20 km to miles"), `12.4274${T}mi`)
})

test("currency: a converted result records that it used a rate", () => {
  const rates = { base: "EUR", rates: { USD: 1.25 } }
  const r = Engine.evaluateSheet("120 usd to eur\n65 eur", { rates })
  assert.equal(r.lines[0].usedRate, true)
  assert.equal(r.lines[1].usedRate, false)
})

test("units: names shadow units from their line down", () => {
  const r = Engine.evaluateSheet("m = 4\nm * 2\n3 km to m")
  assert.equal(r.lines[1].display, "8")
  assert.equal(r.lines[2].display, `3${T}000${T}m`)
})

test("units: adding converts to the left unit", () => {
  assert.equal(display("2 km + 300 m"), `2.3${T}km`)
  assert.equal(display("1 h + 30 min"), `1.5${T}h`)
  assert.equal(Engine.evaluateSheet("2 km + 3 kg").lines[0].error, "can't add km and kg")
})

test("units: arithmetic inside a percentage keeps the unit", () => {
  assert.equal(display("18% of 240 km"), `43.2${T}km`)
  assert.equal(display("100 eur + 20%"), `120${T}EUR`)
})

test("units: `in` stays a unit without a target", () => {
  assert.equal(display("2 in + 3 in"), `5${T}in`)
  assert.equal(display("5 in"), `5${T}in`)
})

test("unicode operators", () => {
  assert.equal(display("6 × 7"), "42")
  assert.equal(display("84 ÷ 2"), "42")
})

test("bare percent value", () => {
  assert.equal(display("18%"), `18${T}%`)
})

test("colouring: classes per span", () => {
  const r = Engine.evaluateSheet("rate = 65 eur # note\nhours * rat\n20 km to miles")
  const cls = line => r.lines[line].spans.map(s => s[2])
  assert.deepEqual(cls(0), ["name", "text", "op", "text", "number", "text", "unit", "text", "comment"])
  assert.deepEqual(cls(1), ["unit", "text", "op", "text", "unknown"])
  assert.deepEqual(cls(2), ["number", "text", "unit", "text", "keyword", "text", "unit"])
})

test("markup: escapes and preserves spaces", () => {
  const r = Engine.evaluateSheet("2  <  3\nx = 1")
  const html = Engine.renderMarkup(r, { number: "#111111", name: "#222222" })
  assert.equal(html.split("<br>").length, 2)
  assert.ok(html.indexOf("&lt;") !== -1)
  assert.ok(html.indexOf("&nbsp;&nbsp;") !== -1)
  assert.ok(html.indexOf('<font color="#222222">x</font>') !== -1)
})

test("sheet summary", () => {
  const r = Engine.evaluateSheet("a = 1\n# note\nb = 2\na + b\n\nzzz")
  assert.deepEqual(r.names, ["a", "b"])
  assert.equal(r.resultCount, 3)
  assert.equal(r.lines.length, 6)
})
