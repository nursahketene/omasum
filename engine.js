// Omasum engine — lexer, parser, units, percentages, bases, formatting and
// the sheet evaluator. Plain JavaScript with no QML imports: the same file
// loads into QML as a library (`import "engine.js" as Engine`) and runs under
// `node --test` for the test vectors. Nothing in here knows about windows or
// colours; colouring is reduced to class names that Theme.qml maps to tokens.

// ---------------------------------------------------------------- units

// Every unit is a dimension plus a factor to that dimension's base.
// Conversion is value * from_factor / to_factor. Temperature and currency
// are handled separately: the first needs offsets, the second live rates.
var UNITS = {
  // length, base m
  mm: ["length", 0.001], cm: ["length", 0.01], dm: ["length", 0.1], m: ["length", 1],
  km: ["length", 1000], in: ["length", 0.0254], ft: ["length", 0.3048], yd: ["length", 0.9144],
  mi: ["length", 1609.344], nmi: ["length", 1852],
  // mass, base kg
  mg: ["mass", 1e-6], g: ["mass", 0.001], kg: ["mass", 1], t: ["mass", 1000],
  oz: ["mass", 0.0283495231], lb: ["mass", 0.45359237], st: ["mass", 6.35029318],
  // volume, base l
  ml: ["volume", 0.001], cl: ["volume", 0.01], l: ["volume", 1], gal: ["volume", 3.785411784],
  qt: ["volume", 0.946352946], pt: ["volume", 0.473176473], cup: ["volume", 0.2365882365],
  floz: ["volume", 0.0295735296],
  // time, base s
  ms: ["time", 0.001], s: ["time", 1], min: ["time", 60], h: ["time", 3600], d: ["time", 86400],
  wk: ["time", 604800], mo: ["time", 2629800], yr: ["time", 31557600],
  // data, base byte. Decimal and binary units are both present and distinct.
  bit: ["data", 0.125], byte: ["data", 1], kb: ["data", 1e3], mb: ["data", 1e6], gb: ["data", 1e9],
  tb: ["data", 1e12], kib: ["data", 1024], mib: ["data", 1048576], gib: ["data", 1073741824],
  tib: ["data", 1099511627776],
  // speed, base km/h
  kmh: ["speed", 1], mph: ["speed", 1.609344], kn: ["speed", 1.852],
  // angle, base deg
  deg: ["angle", 1], rad: ["angle", 57.29577951308232],
  // temperature: offset, not factor — see convertTemperature
  c: ["temperature", 1], f: ["temperature", 1], k: ["temperature", 1]
}

// Long names and plurals resolve to the canonical unit.
var ALIASES = {
  metre: "m", metres: "m", meter: "m", meters: "m",
  kilometre: "km", kilometres: "km", kilometer: "km", kilometers: "km",
  centimetre: "cm", centimetres: "cm", centimeter: "cm", centimeters: "cm",
  millimetre: "mm", millimetres: "mm", millimeter: "mm", millimeters: "mm",
  inch: "in", inches: "in", foot: "ft", feet: "ft", yard: "yd", yards: "yd",
  mile: "mi", miles: "mi",
  gram: "g", grams: "g", kilogram: "kg", kilograms: "kg", kilo: "kg", kilos: "kg",
  pound: "lb", pounds: "lb", lbs: "lb", ounce: "oz", ounces: "oz",
  ton: "t", tons: "t", tonne: "t", tonnes: "t", stone: "st",
  litre: "l", litres: "l", liter: "l", liters: "l", gallon: "gal", gallons: "gal",
  second: "s", seconds: "s", sec: "s", secs: "s", minute: "min", minutes: "min", mins: "min",
  hour: "h", hours: "h", hr: "h", hrs: "h", day: "d", days: "d", week: "wk", weeks: "wk",
  month: "mo", months: "mo", year: "yr", years: "yr",
  celsius: "c", centigrade: "c", fahrenheit: "f", kelvin: "k",
  bytes: "byte", b: "byte", bits: "bit", kilobyte: "kb", kilobytes: "kb",
  megabyte: "mb", megabytes: "mb", gigabyte: "gb", gigabytes: "gb", terabyte: "tb", terabytes: "tb",
  degree: "deg", degrees: "deg", radian: "rad", radians: "rad",
  euro: "eur", euros: "eur", dollar: "usd", dollars: "usd", lira: "try", tl: "try",
  yen: "jpy", franc: "chf", francs: "chf", sterling: "gbp"
}

// Display labels differ from lookup keys.
var LABELS = {
  c: "°C", f: "°F", k: "K", kmh: "km/h", byte: "B", bit: "bit",
  kb: "kB", mb: "MB", gb: "GB", tb: "TB", kib: "KiB", mib: "MiB", gib: "GiB", tib: "TiB"
}

// ISO codes recognised as currency units even before any rates are cached,
// so they colour as units and convert with `rates unavailable` rather than
// `is not a unit`. Anything present in a rates map is a currency too.
var CURRENCIES = ["eur", "usd", "gbp", "try", "jpy", "chf", "aud", "cad", "nzd", "sek", "nok",
  "dkk", "pln", "czk", "huf", "ron", "bgn", "isk", "cny", "hkd", "sgd", "krw", "inr", "brl",
  "mxn", "zar", "ils", "idr", "myr", "php", "thb"]

var CURRENCY_SYMBOLS = { "€": "eur", "$": "usd", "£": "gbp", "₺": "try", "¥": "jpy" }

var CONSTANTS = { pi: Math.PI, e: Math.E, tau: Math.PI * 2, phi: (1 + Math.sqrt(5)) / 2 }

var FUNCTIONS = {
  sqrt: [1, Math.sqrt], cbrt: [1, Math.cbrt], abs: [1, Math.abs], round: [1, Math.round],
  floor: [1, Math.floor], ceil: [1, Math.ceil], exp: [1, Math.exp], ln: [1, Math.log],
  log: [1, Math.log10], log2: [1, Math.log2], sign: [1, Math.sign],
  sin: [1, Math.sin], cos: [1, Math.cos], tan: [1, Math.tan],
  asin: [1, Math.asin], acos: [1, Math.acos], atan: [1, Math.atan],
  // -1 arity means two or more
  min: [-1, function() { return Math.min.apply(null, arguments) }],
  max: [-1, function() { return Math.max.apply(null, arguments) }],
  hypot: [-1, function() { return Math.hypot.apply(null, arguments) }],
  pow: [2, Math.pow]
}

var CONVERSION_WORDS = ["to", "in", "into", "as"]
var BASE_WORDS = ["hex", "bin", "oct", "dec"]
var KEYWORDS = CONVERSION_WORDS.concat(BASE_WORDS, ["of", "percent", "ans", "last"])

function isCurrency(key, rates) {
  if (CURRENCIES.indexOf(key) !== -1) return true
  return !!(rates && rates.rates && Object.prototype.hasOwnProperty.call(rates.rates, key.toUpperCase()))
}

// Canonical unit key for a word, or null. Unknown words ending in `s` get one
// retry with the `s` stripped, which covers plurals the table misses.
function unitKey(word, rates) {
  var w = String(word || "").toLowerCase()
  if (!w) return null
  if (Object.prototype.hasOwnProperty.call(UNITS, w)) return w
  if (Object.prototype.hasOwnProperty.call(ALIASES, w)) return ALIASES[w]
  if (isCurrency(w, rates)) return w
  if (w.length > 1 && w.charAt(w.length - 1) === "s") {
    var singular = w.slice(0, -1)
    if (Object.prototype.hasOwnProperty.call(UNITS, singular)) return singular
    if (Object.prototype.hasOwnProperty.call(ALIASES, singular)) return ALIASES[singular]
    if (isCurrency(singular, rates)) return singular
  }
  return null
}

function unitDimension(key, rates) {
  if (Object.prototype.hasOwnProperty.call(UNITS, key)) return UNITS[key][0]
  if (isCurrency(key, rates)) return "currency"
  return null
}

function unitLabel(key, rates) {
  if (Object.prototype.hasOwnProperty.call(LABELS, key)) return LABELS[key]
  if (unitDimension(key, rates) === "currency") return key.toUpperCase()
  return key
}

function convertTemperature(v, from, to) {
  var c = from === "f" ? (v - 32) * 5 / 9 : from === "k" ? v - 273.15 : v
  return to === "f" ? c * 9 / 5 + 32 : to === "k" ? c + 273.15 : c
}

// Euro-based rate: how many `key` one euro buys. EUR itself is 1.
function currencyRate(key, rates) {
  if (key === "eur") return 1
  if (!rates || !rates.rates) return null
  var r = rates.rates[key.toUpperCase()]
  return (typeof r === "number" && isFinite(r) && r > 0) ? r : null
}

// Converts `v` from unit `from` to unit `to`. Returns { v, usedRate } or
// throws an EngineError with a user-facing message.
function convertUnits(v, from, to, rates) {
  var fromDim = unitDimension(from, rates)
  var toDim = unitDimension(to, rates)
  if (fromDim !== toDim) throw new EngineError("can't convert " + from + " to " + to)
  if (from === to) return { v: v, usedRate: false }
  if (fromDim === "temperature") return { v: convertTemperature(v, from, to), usedRate: false }
  if (fromDim === "currency") {
    var rf = currencyRate(from, rates)
    var rt = currencyRate(to, rates)
    if (rf === null || rt === null) throw new EngineError("rates unavailable")
    return { v: v / rf * rt, usedRate: true }
  }
  return { v: v * UNITS[from][1] / UNITS[to][1], usedRate: false }
}

// ---------------------------------------------------------------- errors

function EngineError(message) {
  this.message = message
}
EngineError.prototype = Object.create(Error.prototype)
EngineError.prototype.name = "EngineError"

// ---------------------------------------------------------------- lexer

function isDigit(ch) { return ch >= "0" && ch <= "9" }
function isIdentStart(ch) { return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch === "_" }
function isIdentChar(ch) { return isIdentStart(ch) || isDigit(ch) }

// Rewrites applied before lexing: currency symbols become trailing unit
// words (`$120` → `120 usd`), and the Unicode operators become ASCII.
function rewrite(code) {
  var out = String(code)
  out = out.replace(/([€$£₺¥])\s*(\d[\d_,]*(?:\.\d+)?)/g, function(_, sym, num) {
    return num + " " + CURRENCY_SYMBOLS[sym]
  })
  out = out.replace(/×/g, "*").replace(/÷/g, "/")
  return out
}

// Reads a number literal starting at `i`. Returns { value, end } or null.
function readNumber(src, i) {
  var n = src.length
  var j = i
  if (src.charAt(j) === "0" && (src.charAt(j + 1) === "x" || src.charAt(j + 1) === "X")) {
    j += 2
    var hs = j
    while (j < n && /[0-9a-fA-F_]/.test(src.charAt(j))) j++
    if (j === hs) return null
    return { value: parseInt(src.slice(hs, j).replace(/_/g, ""), 16), end: j }
  }
  if (src.charAt(j) === "0" && (src.charAt(j + 1) === "b" || src.charAt(j + 1) === "B")) {
    j += 2
    var bs = j
    while (j < n && /[01_]/.test(src.charAt(j))) j++
    if (j === bs) return null
    return { value: parseInt(src.slice(bs, j).replace(/_/g, ""), 2), end: j }
  }
  var text = ""
  var sawDigit = false
  while (j < n) {
    var ch = src.charAt(j)
    if (isDigit(ch)) { text += ch; sawDigit = true; j++; continue }
    if (ch === "_" && sawDigit) { j++; continue }
    // A comma between a digit and exactly three digits is a group separator.
    if (ch === "," && sawDigit && isDigit(src.charAt(j + 1)) && isDigit(src.charAt(j + 2))
        && isDigit(src.charAt(j + 3)) && !isDigit(src.charAt(j + 4))) { j++; continue }
    break
  }
  if (src.charAt(j) === "." && isDigit(src.charAt(j + 1))) {
    text += "."
    j++
    while (j < n && (isDigit(src.charAt(j)) || (src.charAt(j) === "_" && isDigit(src.charAt(j - 1))))) {
      if (src.charAt(j) !== "_") text += src.charAt(j)
      j++
    }
    sawDigit = true
  }
  if (!sawDigit) return null
  // Scientific notation only when digits follow, so `2e` stays 2·e.
  var m = /^[eE]([+-]?\d+)/.exec(src.slice(j))
  if (m) {
    text += "e" + m[1]
    j += m[0].length
  }
  return { value: parseFloat(text), end: j }
}

var OPERATORS = "+-*/^%(),="

function lex(code) {
  var src = rewrite(code)
  var tokens = []
  var i = 0
  var n = src.length
  while (i < n) {
    var ch = src.charAt(i)
    if (ch === " " || ch === "\t") { i++; continue }
    if (isDigit(ch) || (ch === "." && isDigit(src.charAt(i + 1)))) {
      var num = readNumber(src, i)
      if (!num) throw new EngineError("bad number")
      tokens.push({ type: "num", value: num.value, text: src.slice(i, num.end) })
      i = num.end
      continue
    }
    if (isIdentStart(ch)) {
      var s = i
      while (i < n && isIdentChar(src.charAt(i))) i++
      tokens.push({ type: "ident", text: src.slice(s, i) })
      continue
    }
    if (OPERATORS.indexOf(ch) !== -1) {
      tokens.push({ type: "op", text: ch })
      i++
      continue
    }
    throw new EngineError("unexpected " + ch)
  }
  return tokens
}

// ---------------------------------------------------------------- values

// A value carries an optional unit. The first unit seen in an expression
// wins for * and /; + and - convert the right side into the left's unit.
function val(v, unit) { return { v: v, unit: unit || null } }

function combineAdd(a, b, sign, ctx) {
  if (a.unit && b.unit && a.unit !== b.unit) {
    var da = unitDimension(a.unit, ctx.rates)
    var db = unitDimension(b.unit, ctx.rates)
    if (da !== db) throw new EngineError("can't add " + a.unit + " and " + b.unit)
    var conv = convertUnits(b.v, b.unit, a.unit, ctx.rates)
    if (conv.usedRate) ctx.usedRate = true
    return val(a.v + sign * conv.v, a.unit)
  }
  return val(a.v + sign * b.v, a.unit || b.unit)
}

// ---------------------------------------------------------------- parser

// Recursive descent over the token list.
//   add   := mul (('+'|'-') mul)*
//   mul   := unary (('*'|'/'|'%') unary | implicit unary)*
//   unary := ('-'|'+') unary | power
//   power := atom ('^' unary)?
//   atom  := num | name | name '(' args ')' | '(' add ')'
function Parser(tokens, ctx) {
  this.tokens = tokens
  this.pos = 0
  this.ctx = ctx
}

Parser.prototype.peek = function() { return this.tokens[this.pos] }
Parser.prototype.next = function() { return this.tokens[this.pos++] }
Parser.prototype.isOp = function(text) {
  var t = this.peek()
  return !!t && t.type === "op" && t.text === text
}

Parser.prototype.parseAll = function() {
  if (this.tokens.length === 0) throw new EngineError("unfinished line")
  var v = this.parseAdd()
  var t = this.peek()
  if (t) {
    if (t.type === "op" && t.text === ")") throw new EngineError("unexpected )")
    throw new EngineError("unexpected " + t.text)
  }
  return v
}

Parser.prototype.parseAdd = function() {
  var left = this.parseMul()
  while (this.isOp("+") || this.isOp("-")) {
    var op = this.next().text
    var right = this.parseMul()
    left = combineAdd(left, right, op === "+" ? 1 : -1, this.ctx)
  }
  return left
}

Parser.prototype.startsAtom = function() {
  var t = this.peek()
  if (!t) return false
  if (t.type === "num" || t.type === "ident") return true
  return t.type === "op" && t.text === "("
}

Parser.prototype.parseMul = function() {
  var left = this.parseUnary()
  for (;;) {
    if (this.isOp("*") || this.isOp("/") || this.isOp("%")) {
      var op = this.next().text
      var right = this.parseUnary()
      if (op === "*") left = val(left.v * right.v, left.unit || right.unit)
      else if (op === "/") left = val(left.v / right.v, left.unit || right.unit)
      else left = val(left.v % right.v, left.unit || right.unit)
    } else if (this.startsAtom()) {
      // Implicit multiplication: `20 km`, `2pi`, `3(4+1)`.
      var r = this.parseUnary()
      left = val(left.v * r.v, left.unit || r.unit)
    } else {
      return left
    }
  }
}

Parser.prototype.parseUnary = function() {
  if (this.isOp("-")) { this.next(); var a = this.parseUnary(); return val(-a.v, a.unit) }
  if (this.isOp("+")) { this.next(); return this.parseUnary() }
  return this.parsePower()
}

Parser.prototype.parsePower = function() {
  var base = this.parseAtom()
  if (this.isOp("^")) {
    this.next()
    var exp = this.parseUnary()
    return val(Math.pow(base.v, exp.v), base.unit)
  }
  return base
}

Parser.prototype.parseArgs = function() {
  var args = []
  if (this.isOp(")")) { this.next(); return args }
  for (;;) {
    args.push(this.parseAdd())
    if (this.isOp(",")) { this.next(); continue }
    if (this.isOp(")")) { this.next(); return args }
    if (!this.peek()) throw new EngineError("missing )")
    throw new EngineError("unexpected " + this.peek().text)
  }
}

Parser.prototype.parseAtom = function() {
  var t = this.next()
  if (!t) throw new EngineError("unfinished line")
  if (t.type === "num") return val(t.value, null)
  if (t.type === "op" && t.text === "(") {
    var inner = this.parseAdd()
    if (!this.isOp(")")) throw new EngineError("missing )")
    this.next()
    return inner
  }
  if (t.type === "ident") return this.resolveName(t.text)
  if (t.type === "op" && t.text === ")") throw new EngineError("unexpected )")
  throw new EngineError("unfinished line")
}

Parser.prototype.callFunction = function(name) {
  var fn = FUNCTIONS[name]
  this.next() // (
  var args = this.parseArgs()
  var arity = fn[0]
  if (arity === -1 && args.length < 2) throw new EngineError(name + " takes 2 or more arguments")
  if (arity > 0 && args.length !== arity)
    throw new EngineError(name + " takes " + arity + " argument" + (arity === 1 ? "" : "s"))
  var nums = []
  var unit = null
  for (var i = 0; i < args.length; i++) {
    nums.push(args[i].v)
    if (!unit && args[i].unit) unit = args[i].unit
  }
  return val(fn[1].apply(null, nums), unit)
}

// A name resolves in this order: a variable in scope, then ans/last, then a
// constant, then a unit. A name followed by ( is a function call.
Parser.prototype.resolveName = function(text) {
  var name = text.toLowerCase()
  var ctx = this.ctx
  if (this.isOp("(") && Object.prototype.hasOwnProperty.call(FUNCTIONS, name)
      && !Object.prototype.hasOwnProperty.call(ctx.scope, name)) {
    return this.callFunction(name)
  }
  if (Object.prototype.hasOwnProperty.call(ctx.scope, name)) {
    var s = ctx.scope[name]
    return val(s.v, s.unit)
  }
  if (name === "ans" || name === "last") {
    if (!ctx.ans) throw new EngineError("no result yet")
    return val(ctx.ans.v, ctx.ans.unit)
  }
  if (Object.prototype.hasOwnProperty.call(CONSTANTS, name)) return val(CONSTANTS[name], null)
  var unit = unitKey(name, ctx.rates)
  if (unit) return val(1, unit)
  if (Object.prototype.hasOwnProperty.call(FUNCTIONS, name)) throw new EngineError(text + " needs (")
  throw new EngineError(text + " is not defined")
}

function evaluateExpression(code, ctx) {
  var tokens = lex(code)
  return new Parser(tokens, ctx).parseAll()
}

// ---------------------------------------------------------------- formatting

var THIN_SPACE = " "

// The plain string is what gets copied: bare number, no grouping, no unit.
function formatPlain(v) {
  if (typeof v !== "number" || isNaN(v)) return "—"
  if (v === Infinity) return "∞"
  if (v === -Infinity) return "-∞"
  var a = Math.abs(v)
  if (a >= 1e12 || (a < 1e-6 && a !== 0)) return v.toExponential(4).replace("e+", "e")
  var decimals = a >= 100 ? 2 : a >= 1 ? 4 : 6
  var s = v.toFixed(decimals)
  if (s.indexOf(".") !== -1) s = s.replace(/0+$/, "").replace(/\.$/, "")
  if (s === "-0") s = "0"
  return s
}

function formatBase(v, base) {
  var n = Math.round(v)
  if (!isFinite(n)) return formatPlain(v)
  var sign = n < 0 ? "-" : ""
  var a = Math.abs(n)
  if (base === "hex") return "0x" + sign + a.toString(16).toUpperCase()
  if (base === "bin") return "0b" + sign + a.toString(2)
  if (base === "oct") return "0o" + sign + a.toString(8)
  return sign + a.toString(10)
}

function groupThousands(plain) {
  var m = /^(-?)(\d+)(\.\d+)?$/.exec(plain)
  if (!m) return plain
  var int = m[2]
  var out = ""
  while (int.length > 3) {
    out = THIN_SPACE + int.slice(-3) + out
    int = int.slice(0, -3)
  }
  return m[1] + int + out + (m[3] || "")
}

// The display string adds thin-space grouping and the unit label.
function formatDisplay(result, rates) {
  if (result.base) return formatBase(result.value, result.base)
  var s = groupThousands(formatPlain(result.value))
  if (result.percent) return s + THIN_SPACE + "%"
  if (result.unit) return s + THIN_SPACE + unitLabel(result.unit, rates)
  return s
}

// ---------------------------------------------------------------- lines

var ASSIGN_RE = /^([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)\s*(.*)$/
var RESERVED = KEYWORDS.slice()

function splitComment(raw) {
  var idx = raw.indexOf("#")
  if (idx === -1) return { code: raw, comment: "" }
  return { code: raw.slice(0, idx), comment: raw.slice(idx) }
}

// Finds the last conversion separator whose target is a single word, so
// `5 in to cm` converts and `2 in + 3 in` stays arithmetic.
function splitConversion(code) {
  var re = /\s+(to|in|into|as)\s+([A-Za-z_][A-Za-z0-9_]*)\s*$/i
  var m = re.exec(code)
  if (!m) return null
  return { left: code.slice(0, m.index), word: m[1].toLowerCase(), target: m[2] }
}

// Evaluates one line's code against a scope. Returns a result object; never
// throws for user errors, which come back as { error }.
function evaluateLine(code, ctx) {
  var trimmed = code.replace(/^\s+|\s+$/g, "")
  var result = { value: NaN, unit: null, percent: false, base: null, usedRate: false, error: null, name: null }
  if (!trimmed) return null

  var body = trimmed
  var am = ASSIGN_RE.exec(trimmed)
  if (am) {
    result.name = am[1].toLowerCase()
    body = am[2].replace(/^\s+|\s+$/g, "")
    if (RESERVED.indexOf(result.name) !== -1) {
      result.error = "can't assign to " + am[1]
      return result
    }
  }

  try {
    var out = evaluateBody(body, ctx)
    result.value = out.v
    result.unit = out.unit
    result.percent = !!out.percent
    result.base = out.base || null
    result.usedRate = !!ctx.usedRate
  } catch (e) {
    if (e instanceof EngineError) result.error = e.message
    else result.error = "can't evaluate"
  }
  return result
}

function evaluateBody(body, ctx) {
  if (!body) throw new EngineError("unfinished line")

  // 1. `A as % of B` — checked before conversion since `as` is a separator.
  var m1 = /^(.+?)\s+as\s+(%|percent)\s+of\s+(.+)$/i.exec(body)
  if (m1) {
    var a1 = evaluateExpression(m1[1], ctx)
    var b1 = evaluateExpression(m1[3], ctx)
    return { v: a1.v / b1.v * 100, unit: null, percent: true }
  }

  var conv = splitConversion(body)
  var left = conv ? conv.left : body
  var value = evaluatePercentOrExpression(left, ctx)
  if (!conv) return value

  var target = conv.target.toLowerCase()
  if (BASE_WORDS.indexOf(target) !== -1) {
    return { v: value.v, unit: null, percent: false, base: target }
  }
  var toUnit = unitKey(conv.target, ctx.rates)
  if (!toUnit) throw new EngineError(conv.target + " is not a unit")
  if (!value.unit) throw new EngineError("no unit to convert from")
  var converted = convertUnits(value.v, value.unit, toUnit, ctx.rates)
  if (converted.usedRate) ctx.usedRate = true
  return { v: converted.v, unit: toUnit, percent: false }
}

function evaluatePercentOrExpression(code, ctx) {
  // 2. `A% of B` gives B * A / 100, keeping B's unit.
  var m2 = /^(.+?)\s*(%|percent)\s+of\s+(.+)$/i.exec(code)
  if (m2) {
    var a2 = evaluateExpression(m2[1], ctx)
    var b2 = evaluateExpression(m2[3], ctx)
    return val(b2.v * a2.v / 100, b2.unit)
  }
  // 3. `B + A%` and `B - A%` give B * (1 ± A/100), keeping B's unit.
  var m3 = /^(.+?)\s*([+-])\s*([^+\-]+?)\s*(%|percent)$/i.exec(code)
  if (m3) {
    var b3 = evaluateExpression(m3[1], ctx)
    var a3 = evaluateExpression(m3[3], ctx)
    var sign = m3[2] === "+" ? 1 : -1
    return val(b3.v * (1 + sign * a3.v / 100), b3.unit)
  }
  // A bare `A%` is a percentage value shown with the suffix.
  var m4 = /^(.+?)\s*(%|percent)$/i.exec(code)
  if (m4) {
    var a4 = evaluateExpression(m4[1], ctx)
    return { v: a4.v, unit: null, percent: true }
  }
  return evaluateExpression(code, ctx)
}

// ---------------------------------------------------------------- sheet

// Walks the sheet top to bottom. Returns { lines, names, resultCount }.
// Each line: { index, raw, code, comment, kind, name, value, unit, percent,
// base, display, plain, error, usedRate, spans }.
function evaluateSheet(text, options) {
  var opts = options || {}
  var rates = opts.rates || null
  var rawLines = String(text || "").split("\n")
  var scope = {}
  var names = []
  var ans = null
  var lines = []
  var resultCount = 0

  for (var i = 0; i < rawLines.length; i++) {
    var raw = rawLines[i]
    var parts = splitComment(raw)
    var ctx = { scope: scope, ans: ans, rates: rates, usedRate: false }
    var r = evaluateLine(parts.code, ctx)
    var line = {
      index: i, raw: raw, code: parts.code, comment: parts.comment,
      kind: "blank", name: null, value: NaN, unit: null, percent: false, base: null,
      display: "", plain: "", error: null, usedRate: false, spans: []
    }
    if (r) {
      line.name = r.name
      if (r.error) {
        line.kind = "error"
        line.error = r.error
        line.display = r.error
      } else {
        line.kind = r.name ? "assign" : "value"
        line.value = r.value
        line.unit = r.unit
        line.percent = r.percent
        line.base = r.base
        line.usedRate = r.usedRate
        line.plain = r.base ? formatBase(r.value, r.base) : formatPlain(r.value)
        line.display = formatDisplay(r, rates)
        resultCount++
        if (r.name) {
          if (!Object.prototype.hasOwnProperty.call(scope, r.name)) names.push(r.name)
          scope[r.name] = { v: r.value, unit: r.unit }
        }
        if (isFinite(r.value)) ans = { v: r.value, unit: r.unit }
      }
    }
    // Colouring sees the scope as of this line, including a name being
    // defined on it, so the left side of `x = 2` paints as a name at once.
    line.spans = colourLine(raw, scope, r && r.name ? r.name : null, rates)
    lines.push(line)
  }
  return { lines: lines, names: names, resultCount: resultCount }
}

// ---------------------------------------------------------------- colouring

// Classes: comment, number, op, unit, keyword, func, const, name, unknown,
// text. Theme.qml maps them to tokens. Spans are [start, end, cls] over the
// raw line, contiguous and covering every character.
function classifyWord(word, scope, definingName, rates) {
  var w = word.toLowerCase()
  if (definingName && w === definingName) return "name"
  if (Object.prototype.hasOwnProperty.call(scope, w)) return "name"
  if (KEYWORDS.indexOf(w) !== -1) return "keyword"
  if (Object.prototype.hasOwnProperty.call(FUNCTIONS, w)) return "func"
  if (Object.prototype.hasOwnProperty.call(CONSTANTS, w)) return "const"
  if (unitKey(w, rates)) return "unit"
  return "unknown"
}

function colourLine(raw, scope, definingName, rates) {
  var spans = []
  var parts = splitComment(raw)
  var code = parts.code
  var i = 0
  var n = code.length
  while (i < n) {
    var ch = code.charAt(i)
    if (isIdentStart(ch)) {
      var s = i
      while (i < n && isIdentChar(code.charAt(i))) i++
      spans.push([s, i, classifyWord(code.slice(s, i), scope, definingName, rates)])
      continue
    }
    if (isDigit(ch) || (ch === "." && isDigit(code.charAt(i + 1)))) {
      var num = readNumber(code, i)
      var end = num ? num.end : i + 1
      spans.push([i, end, "number"])
      i = end
      continue
    }
    if (OPERATORS.indexOf(ch) !== -1 || ch === "×" || ch === "÷") {
      spans.push([i, i + 1, "op"])
      i++
      continue
    }
    if (Object.prototype.hasOwnProperty.call(CURRENCY_SYMBOLS, ch)) {
      spans.push([i, i + 1, "unit"])
      i++
      continue
    }
    var t = i
    while (i < n && !isIdentStart(code.charAt(i)) && !isDigit(code.charAt(i))
        && OPERATORS.indexOf(code.charAt(i)) === -1 && "×÷".indexOf(code.charAt(i)) === -1
        && !Object.prototype.hasOwnProperty.call(CURRENCY_SYMBOLS, code.charAt(i))) i++
    if (i === t) i++
    spans.push([t, i, "text"])
  }
  if (parts.comment) spans.push([n, raw.length, "comment"])
  return spans
}

function escapeMarkup(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;")
}

// Builds Text.StyledText markup for the whole sheet. `palette` maps a class
// name to a colour string; classes missing from it are left uncoloured.
function renderMarkup(sheet, palette) {
  var out = []
  for (var i = 0; i < sheet.lines.length; i++) {
    var line = sheet.lines[i]
    var raw = line.raw
    var parts = []
    for (var j = 0; j < line.spans.length; j++) {
      var span = line.spans[j]
      var textPart = escapeMarkup(raw.slice(span[0], span[1]))
      var colour = palette[span[2]]
      var piece = colour ? '<font color="' + colour + '">' + textPart + "</font>" : textPart
      if (span[2] === "comment") piece = "<i>" + piece + "</i>"
      parts.push(piece)
    }
    out.push(parts.join(""))
  }
  return out.join("<br>")
}

// ---------------------------------------------------------------- exports

var Engine = {
  evaluateSheet: evaluateSheet,
  evaluateLine: evaluateLine,
  renderMarkup: renderMarkup,
  colourLine: colourLine,
  formatPlain: formatPlain,
  formatBase: formatBase,
  unitKey: unitKey,
  unitLabel: unitLabel,
  lex: lex,
  EngineError: EngineError,
  THIN_SPACE: THIN_SPACE
}

if (typeof module !== "undefined" && module.exports) module.exports = Engine
