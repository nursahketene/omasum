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

test("trig: results drop the angle unit", () => {
  assert.deepEqual(sheet("a = 30 deg in rad\nsin(a)"), [`0.523599${T}rad`, "0.5"])
})

test("trig: degrees are converted to radians", () => {
  assert.deepEqual(sheet("sin(30 deg)\ntan(45 degrees)\ncos(pi rad)"), ["0.5", "1", "-1"])
})

test("units: decilitres and long prefixed names", () => {
  assert.deepEqual(sheet("1 liter to deciliter\n250 millilitres to dl\n500 milligrams to g\n3 decimeters to cm"),
    [`10${T}dl`, `2.5${T}dl`, `0.5${T}g`, `30${T}cm`])
})

test("units: nano, micro, deca and hecto", () => {
  assert.deepEqual(sheet("500 nm to um\n5 μg to mg\n2 µm to nm\n3 hectolitres to l\n1 dam to m\n100 us to ms"),
    [`0.5${T}µm`, `0.005${T}mg`, `2${T}000${T}nm`, `300${T}l`, `10${T}m`, `0.1${T}ms`])
})

test("units: peta, bits and binary long names", () => {
  assert.deepEqual(sheet("1 pb to tb\n100 mbit to mb\n1 tebibyte to gib"),
    [`1${T}000${T}TB`, `12.5${T}MB`, `1${T}024${T}GiB`])
})

test("functions: rounding keeps the unit, sign drops it", () => {
  assert.deepEqual(sheet("round(2.6 km)\nabs(-4 h)\nsign(-3 kg)"), [`3${T}km`, `4${T}h`, "-1"])
})

test("functions: min, max and hypot convert to the first unit", () => {
  assert.deepEqual(sheet("min(1 km, 500 m)\nhypot(3 m, 400 cm)\nmax(5, 3 km)"),
    [`0.5${T}km`, `5${T}m`, `5${T}km`])
})

const errors = [
  ["hours * rat", "rat is not defined"],
  ["12 km to kg", "can't convert km to kg"],
  ["12 km to kgg", "kgg is not a unit"],
  ["240 to eur", "no unit to convert from"],
  ["2 +", "unfinished line"],
  ["(2 + 3", "missing )"],
  ["1 ks", "ks is not defined"],
  ["sin(3 kg)", "can't take sin of kg"],
  ["asin(1 rad)", "can't take asin of rad"],
  ["sqrt(100 eur)", "can't take sqrt of eur"],
  ["ln(5 kg)", "can't take ln of kg"],
  ["pow(2 m, 3)", "can't take pow of m"],
  ["max(2 kg, 3 km)", "can't mix kg and km"],
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
  // Plain spaces: the sheet's pre-wrap block keeps them and can wrap there.
  assert.ok(html.indexOf("&nbsp;") === -1)
  assert.ok(html.indexOf("  ") !== -1)
  assert.ok(html.indexOf('<font color="#222222">x</font>') !== -1)
})

test("sheet summary", () => {
  const r = Engine.evaluateSheet("a = 1\n# note\nb = 2\na + b\n\nzzz")
  assert.deepEqual(r.names, ["a", "b"])
  assert.equal(r.resultCount, 3)
  assert.equal(r.lines.length, 6)
})

// `@n` completion: what Tab would put in place of the reference.
function complete(text, index, col) {
  const s = Engine.evaluateSheet(text)
  const lines = text.split("\n")
  return Engine.completeReference(s, index, col === undefined ? lines[index].length : col)
}

test("reference: plain value pastes the exact number", () => {
  const r = complete("10/3\n@1", 1)
  assert.equal(r.text, "3.3333333333333335")
  assert.deepEqual([r.start, r.end, r.line], [0, 2, 1])
})

test("reference: the pasted text evaluates to the same value", () => {
  for (const src of ["10/3", "2^70", "1/3e9", "75 kg to lbs", "92 f to c", "90 km/h", "-4 m",
                     "18% of 240", "84 as % of 400", "255 to hex", "65 eur", "2.5 GB to MiB"]) {
    const s = Engine.evaluateSheet(src + "\n@1")
    const text = Engine.completeReference(s, 1, 2).text
    const back = Engine.evaluateSheet(text).lines[0]
    assert.equal(back.value, s.lines[0].value, `${src} → ${text}`)
    assert.equal(back.unit, s.lines[0].unit, `${src} → ${text}`)
  }
})

test("reference: units carry, with labels that read back", () => {
  assert.equal(complete("5 kg\n@1", 1).text, "5 kg")
  assert.equal(complete("100 c\n@1", 1).text, "100 c")
  assert.equal(complete("2 MiB\n@1", 1).text, "2 MiB")
  assert.equal(complete("12 to hex\n@1", 1).text, "0xC")
  assert.equal(complete("18%\n@1", 1).text, "18%")
})

test("reference: brackets only when the value is not the whole expression", () => {
  assert.equal(complete("5 kg\nx = @1", 1).text, "5 kg")
  assert.equal(complete("5 kg\n@1 # note", 1, 2).text, "5 kg")
  assert.equal(complete("5 kg\n@1^2", 1, 2).text, "(5 kg)")
  assert.equal(complete("-3\n2 * @1", 1).text, "(-3)")
  assert.equal(complete("3\n2 * @1", 1).text, "3")
})

test("reference: only a valid result completes", () => {
  assert.equal(complete("\n@1", 1).error, "line 1 has no result")
  assert.equal(complete("# note\n@1", 1).error, "line 1 has no result")
  assert.equal(complete("2 +\n@1", 1).error, "line 1 has an error")
  assert.equal(complete("1/0\n@1", 1).error, "line 1 has no result")
  assert.equal(complete("2\n@9", 1).error, "no line 9")
  assert.equal(complete("2\n@0", 1).error, "no line 0")
  assert.equal(complete("@1", 0).error, "that's this line")
  assert.equal(complete("@3\n\n7", 0).text, "7")
})

test("reference: only right before the cursor, outside comments", () => {
  assert.equal(complete("2\n@1 + 1", 1, 6), null)
  assert.equal(complete("2\n@12", 1, 2), null)
  assert.equal(complete("2\n@1x", 1, 2), null)
  assert.equal(complete("2\n# see @1", 1), null)
  assert.equal(complete("2\n1 + 1", 1), null)
})

// Currency symbols: before or after the number, or as the conversion target.
test("currency symbols read wherever they are written", () => {
  const rates = { rates: { EUR: 1, USD: 1.1, GBP: 0.85, INR: 92 } }
  const d = s => Engine.evaluateSheet(s, { rates }).lines[0].display
  assert.equal(d("$120"), `120${T}USD`)
  assert.equal(d("120€"), `120${T}EUR`)
  assert.equal(d("120 €"), `120${T}EUR`)
  assert.equal(d("$1,200.50"), `1${T}200.5${T}USD`)
  assert.equal(d("-$5"), `-5${T}USD`)
  assert.equal(d("₹500"), `500${T}INR`)
  assert.equal(d("120 eur to $"), `132${T}USD`)
  assert.equal(d("€120 in £"), `102${T}GBP`)
  assert.equal(d("100€ + 10%"), `110${T}EUR`)
  assert.equal(d("x = 5£"), `5${T}GBP`)
  assert.equal(d("€5 # costs $ later"), `5${T}EUR`)
})

test("currency symbols colour as units", () => {
  const spans = Engine.colourLine("120€ to £", {}, null, null)
  assert.deepEqual(spans.filter(s => s[2] === "unit").map(s => s[0]), [3, 8])
})

// Name completion: the rest of a name defined above, for Tab to insert.
function completeN(text, index, col) {
  const s = Engine.evaluateSheet(text)
  const lines = text.split("\n")
  return Engine.completeName(s, index, col === undefined ? lines[index].length : col)
}

test("name completion: offers the rest of a name defined above", () => {
  const r = completeN("rent = 1450\nre", 1)
  assert.deepEqual([r.name, r.text, r.start, r.end, r.more], ["rent", "rent", 0, 2, 0])
  assert.equal(r.value, `1${T}450`)
  assert.deepEqual(completeN("rent = 1450\n2 * Re", 1).text, "rent")
  assert.equal(completeN("rent = 1450\nre + 2", 1, 2).text, "rent")
})

test("name completion: shortest match first, then the latest defined", () => {
  const r = completeN("rates = 2\nrate = 1\nrentals = 3\nr", 3)
  assert.equal(r.name, "rate")
  assert.equal(r.more, 2)
  assert.equal(completeN("rb = 1\nra = 2\nr", 2).name, "ra")
})

test("name completion: only where a name is being typed", () => {
  assert.equal(completeN("rent = 1450\nrent", 1), null)
  assert.equal(completeN("rent = 1450\nrex", 1), null)
  assert.equal(completeN("rent = 1450\nreq", 1, 2), null)
  assert.equal(completeN("rent = 1450\n# re", 1), null)
  assert.equal(completeN("rent = 1450\n2re", 1), null)
  assert.equal(completeN("re\nrent = 1450", 0), null)
  assert.equal(completeN("rent = 1450\n", 1), null)
  assert.equal(completeN("rent = 2 +\nre", 1), null)
})

test("name completion: keeps the name's case as defined", () => {
  const r = completeN("monthlyRent = 1450\nmon", 1)
  assert.deepEqual([r.name, r.text, r.start, r.end], ["monthlyRent", "monthlyRent", 0, 3])
  assert.equal(completeN("monthlyRent = 1450\n2 * MONTH", 1).text, "monthlyRent")
  assert.equal(completeN("  Total = 1\ntot", 1).text, "Total")
  assert.equal(completeN("Rate = 1\nRATE = 2\nra", 2).text, "RATE")
})

test("scope names keep their case, as the latest definition writes it", () => {
  assert.deepEqual(Engine.evaluateSheet("monthlyRent = 1450\nVAT = 20%\nmonthlyRent * 12").names, ["monthlyRent", "VAT"])
  assert.deepEqual(Engine.evaluateSheet("Rate = 1\nb = 2\nRATE = 3").names, ["RATE", "b"])
})
