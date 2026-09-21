# Omasum — implementation handover

2026-09-20 · design and spec by Nur, with Claude

## Scope

Build **Omasum**: a keybind-summoned calculator overlay that behaves like a notepad. You type lines of plain text, each line's result appears in a column on the right, and the whole sheet re-evaluates top to bottom on every keystroke.

The design is settled and prototyped. The artboards live in the **Omasum overlay** design canvas: `Sheet — live` is a working prototype carrying the real parser, `Syntax` is the in-app help screen, plus `Theme tokens`, `States` and `System theme`. The grammar, unit tables, formatting and colouring rules below are transcribed from that prototype's `project/Main.dc.html`, not invented for this document — read it when a detail here is ambiguous.

Settled, not open for re-litigation:

- A **sheet**, not a prompt. No input line, no history list, no equals button, no keypad.
- **Results in a right-hand column**, aligned line for line with the text.
- **Live colouring** as you type: units and keywords in one accent, your own names in a second, unrecognised words in red.
- **Comments with `#`**, at the start of a line or trailing an expression.
- **Eleven colour tokens** read from the current Omarchy theme, repainted on a theme switch. No per-theme code path, no light-mode branch.
- **One autosaved sheet** that survives closing the overlay.
- **A QML shell plugin for Omarchy 4**, toggled by keybind over the shell's IPC.

This document should be enough to implement without coming back to the designer. Where it gives a number, use that number. Where it says *verify on the machine*, verify — parts of Omarchy move faster than this document.

## Stack and architecture

An Omarchy 4 shell plugin: QML for the surface, plain JavaScript for the engine, running inside the Quickshell process the desktop already keeps alive. No binary, no daemon, no socket, no service unit. Everything the GTK design had to build — instant appearance, live theming, a place to live — comes free from living in the shell.

User plugins go in `~/.config/omarchy/plugins/`, discovered at startup alongside the first-party ones in `$OMARCHY_PATH/shell/plugins/`:

```
~/.config/omarchy/plugins/omasum/
  manifest.json
  Omasum.qml      panel entry point, the window
  Sheet.qml       editor and result column
  engine.js       lexer, parser, units, formatting
  Theme.qml       token mapping, derived accent2, contrast guard
```

`manifest.json` needs `schemaVersion` 1, the id `dev.nur.omasum` — namespaced, since `omarchy.*` is reserved for first-party plugins — plus `name` ("Omasum"), `version`, `author`, `description`, `kinds: ["panel"]` and `entryPoints: {"panel": "Omasum.qml"}`. Panel is the kind for a floating, summoned window. Run `omarchy plugin validate ./omasum` before wondering why nothing appears, then `omarchy plugin enable dev.nur.omasum`; enabled state is recorded in `~/.config/omarchy/shell.json`.

**`engine.js` is the discipline that matters.** A pure JavaScript module with no QML imports: the same file loads into QML as a library and runs under `node --test` for the test vectors. Every parsing, unit and formatting decision lives there; nothing about windows or colours does. It is the part worth getting right, and the only part where correctness is hard.

**Read the first-party plugins before writing QML.** The manual and `shell/README.md` cover the manifest and the IPC contract but not the QML patterns — window declaration, how a panel receives its toggle payload and dismisses itself, the exact singleton property names. Those live in the source: `shell/plugins/` in the Omarchy repo, with `osd/Osd.qml` as a panel-kind example. Copy the shapes from there rather than inventing them.

## The sheet model

The document text is the only state. There is no stored list of results, no committed history, no dirty flag per line. On every change, split the text into lines, walk them in order, and evaluate each against a scope built from the lines above it. That single rule gives you propagation for free: editing a line high up recomputes everything under it because everything under it is computed fresh anyway.

The walk, per line:

1. Split off the comment. Everything from the first `#` to the end of the line is a note. What remains is the code.
2. If the code is blank, the line has no result. Blank lines and comment-only lines are legal and common.
3. If the code matches `name = expression`, evaluate the expression, bind `name` in scope, and show the value.
4. Otherwise evaluate the code and show the value.
5. If the line produced a finite number, bind `ans` and `last` to it for the lines below.
6. On an error, show the message in the result column and carry on. One bad line never stops the lines under it.

Scope is a flat map from lowercase name to value, and a value carries an optional unit. That is why `leg = 18 km` then `leg * 2 to miles` works: the binding remembers kilometres. Names are case-insensitive and resolve before units, so a sheet that defines `m = 4` shadows metres from that line down. Accept it; the colouring shows the user which one they got.

A name is visible only below its definition. Using a name before it is defined is an error on that line, not a forward reference. This keeps evaluation a single pass and keeps the sheet readable top to bottom.

Re-evaluating the whole sheet on each keystroke is affordable at the sizes this app sees. A 200-line sheet is well under a millisecond, even in JavaScript. Do not build dependency tracking or incremental recomputation. If a sheet ever gets slow enough to matter, debounce by 16ms and re-measure before adding machinery.

## Grammar

A recursive-descent parser over a hand-written lexer, in plain JavaScript in engine.js. No parser generator, no dependencies: the language is small and the error messages matter more than the grammar's elegance.

**Lexing.** Whitespace separates but is otherwise ignored. Numbers are decimal digits with optional `.`, and `_` is a legal group separator that is stripped (`1_000_000`). `0x` prefixes hex, `0b` prefixes binary. A comma between a digit and exactly three digits is a group separator and is stripped, so `1,000` is one thousand while `min(1,2)` keeps its argument comma. Identifiers start with a letter or `_` and continue with letters, digits or `_`. Operators are `+ - * / ^ % ( ) ,` plus `=` at statement level; `x` as a multiplication sign is not accepted, but the Unicode `×` and `÷` are.

**Precedence**, loosest to tightest:

| Level | Operators | Associativity |
| --- | --- | --- |
| 1 | `+` `-` | left |
| 2 | `*` `/` `%` and implicit multiplication | left |
| 3 | unary `-` `+` | right |
| 4 | `^` | right |
| 5 | atoms: number, name, `name(args)`, `( expr )` |  |

`%` at level 2 is modulo. The percentage forms are recognised before parsing begins, so `10 % 3` is 1 while `10% of 3` is a percentage.

**Implicit multiplication** binds at level 2: when a number, name or `(` follows a complete atom with no operator between them, multiply. This is what makes `20 km` work, since a bare unit evaluates to 1 and tags the expression with its unit. It also gives you `2pi` and `3(4+1)` for free.

**Atoms.** A number is itself. A name resolves in this order: a variable in scope, then `ans` or `last`, then a constant, then a unit. A name followed by `(` is a function call. Anything unresolved is an error reading `<name> is not defined`.

Constants: `pi`, `e`, `tau`, `phi`.

Functions, all taking one argument except `min`, `max`, `pow` and `hypot`: `sqrt`, `cbrt`, `abs`, `round`, `floor`, `ceil`, `exp`, `ln`, `log` (base 10), `log2`, `sign`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `min`, `max`, `hypot`, `pow`. Trigonometric functions take radians.

**Error messages are UI.** They appear in the result column where a number would be, so keep them short, lowercase and specific: `rat is not defined`, `missing )`, `can't convert km to kg`, `kgg is not a unit`, `unfinished line`. Never surface a JavaScript exception message or a character offset.

## Units, percentages and bases

**The unit table.** Every unit is a dimension plus a factor to that dimension's base. Conversion is `value * from_factor / to_factor`. A unit token evaluates to 1 and tags the expression; the first unit seen in an expression wins, so `2 * 3 km` is 6 km.

| Dimension | Base | Units |
| --- | --- | --- |
| length | m | mm 0.001, cm 0.01, dm 0.1, m 1, km 1000, in 0.0254, ft 0.3048, yd 0.9144, mi 1609.344, nmi 1852 |
| mass | kg | mg 1e-6, g 0.001, kg 1, t 1000, oz 0.0283495231, lb 0.45359237, st 6.35029318 |
| volume | l | ml 0.001, cl 0.01, l 1, gal 3.785411784, qt 0.946352946, pt 0.473176473, cup 0.2365882365, floz 0.0295735296 |
| time | s | ms 0.001, s 1, min 60, h 3600, d 86400, wk 604800, mo 2629800, yr 31557600 |
| data | byte | bit 0.125, byte 1, kb 1e3, mb 1e6, gb 1e9, tb 1e12, kib 1024, mib 1048576, gib 1073741824, tib 1099511627776 |
| speed | km/h | kmh 1, mph 1.609344, kn 1.852 |
| angle | deg | deg 1, rad 57.29577951308232 |
| temperature | °C | c, f, k — offset, not factor |
| currency | EUR | see the rates section |

Decimal and binary data units are both present and distinct: `2.5 GB to MiB` is 2384.19, not 2560. That is correct and deliberate.

**Temperature** cannot use factors. Convert to Celsius first (`f` is `(v-32)*5/9`, `k` is `v-273.15`), then out of Celsius (`f` is `v*9/5+32`, `k` is `v+273.15`).

**Aliases.** Long names and plurals resolve to the canonical unit: metre/meters/metres, kilometre(s), inch/inches, foot/feet, mile(s), gram(s), kilogram(s)/kilo(s), pound(s)/lbs, ounce(s), ton(s)/tonne(s), stone, litre(s)/liter(s), gallon(s), second(s)/sec(s), minute(s)/mins, hour(s)/hr(s), day(s), week(s), month(s), year(s), celsius/centigrade, fahrenheit, kelvin, byte(s)/b, bit(s), kilobyte(s), megabyte(s), gigabyte(s), terabyte(s), degree(s), radian(s), euro(s), dollar(s), lira/tl, yen, franc(s), sterling. Unknown words ending in `s` get one retry with the `s` stripped, which covers plurals the table misses.

**Display labels** differ from lookup keys: `c` shows as °C, `f` as °F, `kmh` as km/h, `byte` as B, `kb` as kB, `mib` as MiB, and currencies uppercase to EUR, USD, TRY and so on.

**Currency symbols** are rewritten before lexing: a leading `€`, `$`, `£`, `₺` or `¥` becomes a trailing unit word, so `$120 in eur` parses as `120 usd in eur`.

**Conversion.** The separator is `to`, `in`, `into` or `as`, and the **last** occurrence in the line wins — that is what makes `5 in to cm` work, where `in` is both a unit and a keyword. If the target is not a unit and not a base word, the line is an error saying so. If the left side has no unit, the error is `no unit to convert from`.

**Percentages**, recognised before the expression parser in this order:

1. `A as % of B` gives `A / B * 100`, displayed with a `%` suffix. `percent` works in place of `%`.
2. `A% of B` gives `B * A / 100`, keeping B's unit.
3. `B + A%` and `B - A%` give `B * (1 ± A/100)`, keeping B's unit.

**Bases.** `to hex`, `to bin`, `to oct` and `to dec` round the value to an integer and format it as `0xFF`, `0b1100`, `0o17` or a plain integer. Negative values keep the sign after the prefix.

## Number formatting

Two strings come out of every result: the **display** string for the result column and the **plain** string for the clipboard. They differ, and that difference is a feature.

The plain string, which is what gets copied:

1. Not finite: `—` for NaN, `∞` or `-∞` for infinities.
2. Absolute value at or above 1e12, or below 1e-6 and not zero: scientific with four decimals, `e+` collapsed to `e`.
3. Otherwise round to a magnitude-dependent number of decimals — 2 at or above 100, 4 from 1 up to 100, 6 below 1 — then strip trailing zeros and any trailing point.

The display string adds a thin space (U+2009) as a thousands separator, then a thin space and the unit label, or a thin space and `%` for a percentage result. Thin spaces rather than commas or periods: the sheet is read by someone who writes 1 450,50 in one context and 1,450.50 in another, and a thin space is unambiguous in both. Digits stay in a monospace face so columns line up.

So 27120 displays as `27 120` and copies as `27120`. A conversion displays as `12.4274 mi` and copies as `12.4274`. Copy gives the bare number because the destination is usually a spreadsheet cell, a commit message or another calculation.

The magnitude-dependent precision is what keeps a sheet legible: money lands on cents, ratios keep four places, and small factors keep six. Do not replace it with a fixed precision or a significant-figures scheme without seeing a sheet in both.

## Theme contract

Eleven tokens carry the entire surface. Nothing in the app names a colour; everything reads a token.

| Token | What it paints |
| --- | --- |
| `base` | The sheet background |
| `surface` | Top and bottom bars, the lit row after a copy |
| `overlay` | The copied pill |
| `border` | The column rule, bar separators |
| `text` | Expression text, results |
| `muted` | Comments, bar labels, operators, placeholder |
| `accent` | Window border, caret, units, keywords, functions |
| `accent2` | Names the user defined, and only those |
| `ok` | An assignment's value in the result column |
| `warn` | A stale or placeholder currency rate |
| `err` | A failed line, and an unrecognised word mid-typing |

**Where they come from.** Inside the shell, you do not parse theme files at all. Omarchy 4 exposes the active theme to QML as singletons: `Color` for palette values and surface roles (`Color.menu.border` is the documented shape), `Style` for spacing, typography, corner radius and bar sizing. Bind the eleven tokens to those properties and a theme switch repaints the sheet with no code of ours running — property bindings do it.

This is the largest saving from moving to QML, so do not undo it by reading `colors.toml` yourself. The file, its 24 semantic colours and the `~/.config/omarchy/shell.toml` machine override are all upstream of those singletons; the shell has already merged them by the time a plugin loads. Take the singleton values.

The exact property names are not in the manual — read them off a first-party plugin's QML and the shell's colour definitions. Map our tokens onto whatever surface roles the shell already names, preferring a role that means the same thing (a menu's background for `base`, its border for `border`) over a raw palette colour, so the calculator tracks the rest of the desktop when a theme redefines a role.

Two tokens still need work of our own, in `Theme.qml`, as computed properties so they re-derive whenever the singletons change.

`accent2` has to be **derived**, because no theme declares a second accent. From the named palette colours, drop any within about 40 degrees of hue of `accent` and pick the one closest to it in lightness; if too few are named, rotate `accent` 120 degrees in OKLCH keeping its chroma and lightness. This matters more than it sounds: `accent2` is the only signal that a word is a name you defined rather than a unit, so it must never collide with `accent`.

Contrast has to be **enforced at load**, not assumed. Community themes are not vetted, and several stock ones have a `muted` sitting at about 4.4:1 on their own background — I hit this designing against Nord. After mapping, walk each foreground token's OKLCH lightness away from `base` until it reaches 4.5:1 against the surface it sits on. Direction comes from whether the theme is light. A guard that silently fixes a bad theme is the difference between this working on every theme and working on the seven I checked.

Sources: [omarchy/docs/theming.md on the quattro branch](https://github.com/omacom/omarchy/blob/quattro/docs/theming.md), [Omarchy v4.0.0 release notes](https://github.com/omacom/omarchy/releases/tag/v4.0.0) and [Omarchy 4.0 Quattro, Linuxiac](https://linuxiac.com/arch-based-omarchy-4-0-quattro-is-here-with-its-biggest-desktop-overhaul-yet/).

## Window and layout

820 × 600 logical pixels, centred, 14px corner radius, a 2px border in `accent`, background `base`, one drop shadow. It does not resize in the first cut; the sheet scrolls instead. Where `Style` has an opinion on radius or spacing, prefer it, so the panel reads as part of the same shell as the menus.

Top to bottom: a 33px top bar, the sheet, a 33px bottom bar.

**Top bar.** Background `surface`, 1px `border` underneath, 11px sans. Left: `↵ new line`, `# comment`, `click a result to copy`, then `? syntax` as a link that opens the help screen. The key names are `text`, the words around them `muted`. Right: the Clean sheet button with a trash glyph, `muted`, turning `err` on hover.

**The sheet** is one scroll area holding a 12px spacer, one 30px row per line, then a filler that takes the remaining height. Each row is two columns: the editor on the left, a fixed 210px result column on the right with a 1px `border` down its left edge. That rule runs through the spacer and the filler too, so it reaches from bar to bar like the margin rule on ruled paper. Clicking the filler puts the cursor at the end of the last line.

**Metrics that matter.** Row height 30px, text 17px, horizontal padding 18px on both columns, results right-aligned at 15px. Comments italic. The result column ellipsises rather than wrapping. Row height and text size are one pair — change one and the gutter stops lining up.

**The editor, and the one place QML costs us something.** Qt's real answer to syntax colouring is `QSyntaxHighlighter`, which is C++ and out of reach from a QML plugin. So the prototype's approach is not a browser workaround to be replaced — it is the approach here too: a transparent `TextEdit` over a `Text` element that paints the coloured copy.

The mechanics:

- One `TextEdit` holding the whole sheet, `color` transparent. It owns the cursor, the selection, undo and every key.
- Behind it a `Text` with `textFormat: Text.StyledText`, its markup rebuilt from `engine.js` on every change. Identical `font.family`, `font.pixelSize`, `lineHeight` and padding, or the two layers drift.
- `selectedTextColor` transparent and a `selectionColor` at roughly 30% alpha, so a selection tints the coloured text underneath instead of hiding it.
- `wrapMode: TextEdit.NoWrap`, which is the design anyway, and which keeps every line exactly one row tall so the result column stays aligned.

The result column is a separate column of rows beside it, one 30px row per line, both inside one `Flickable` so they scroll together. Do not give the two their own scroll positions.

What this keeps that the prototype lost: `TextEdit` is a single field, so selection spans lines, `Ctrl+Z` works, and the cursor moves the way a cursor should. What to watch: rebuilding the `Text` markup on every keystroke must never touch the `TextEdit`'s text, cursor or selection. The two layers share metrics, never state.

**States.** All four are drawn on the `States` artboard.

- *Empty:* a single ghost line in `muted` italic reading `# a scratch sheet — every line is live`, cleared on the first keystroke. The bottom bar reads `empty sheet`.
- *Working:* results right, assignments in `ok`, names in the bottom bar.
- *Error:* the unrecognised word red in the line, the message in the result column. Other lines unaffected.
- *Copied:* the row's background lifts to `surface` and a pill appears bottom-right — a check in `ok`, the value, then `copied` in `muted`. Both clear after 1.8 seconds.

**Bottom bar.** Left: `in scope` followed by the names currently defined, in `accent2`, monospace, clipped when they overflow; when none, `nothing yet — write name = value on any line` in italic. Right: `<n> lines · <m> results`.

**Type.** Monospace across the sheet and for the names in the bottom bar; the shell's UI face for bar labels and the help screen's prose. Take both from the `Style` singleton rather than naming families here, so the calculator follows a user's font choice in `shell.toml` the same way the bar does. The prototype's JetBrains Mono and IBM Plex Sans are a stand-in for whatever `Style` provides.

## Keys and interaction

With one `TextEdit` holding the sheet, most of this is what the element already does. Do not reimplement it.

| Key | Behaviour |
| --- | --- |
| Enter | New line. Nothing is committed, because nothing is ever committed |
| Arrows, Home, End, PgUp, PgDn | Native cursor movement |
| Shift with movement, mouse drag, double and triple click | Native selection, across lines |
| Ctrl+A, Ctrl+C, Ctrl+V, Ctrl+X, Ctrl+Z | Native, including undo |
| Escape | Hide the window. Never clears the sheet |
| Click a result | Copy that line's plain value |
| Click below the last line | Cursor to the end of the sheet |

Escape hides rather than clears, and the sheet comes back exactly as it was — same text, same cursor line. The only thing that empties a sheet is Clean sheet. That asymmetry is the point: closing is free, discarding is deliberate.

**Focus.** The editor takes focus the moment the window shows, with the cursor where it was. Nothing else in the window is focusable except the Clean sheet button and the syntax link, both reachable by Tab.

**Copy** writes to the clipboard on click — not the selection, the clipboard — and shows the pill. Copy the plain value, without grouping and without the unit. A line with no result, a comment or a failed line, is not clickable and shows no hover state.

**Clean sheet** empties the editor, clears the saved file and puts the cursor on line one. No confirmation in the first cut, because Ctrl+Z is right there — but check that `TextEdit`'s undo stack actually covers a programmatic clear, and if it does not, hold the previous text in a property for one undo.

**Re-evaluation** runs on the editor's text change. Sequence: read the text, evaluate in `engine.js`, rebuild the coloured markup, update the result rows, update the bottom bar. Never write back into the editor during re-evaluation; the sheet's text belongs to the user alone.

One QML-specific trap: do not bind the coloured `Text`'s markup directly to the editor's `text` property with an inline expression that calls the engine. Compute it in a change handler and assign it, so the engine runs once per change rather than once per binding re-evaluation.

## Persistence

One sheet, autosaved, at `~/.local/state/omasum/sheet.calc`. Plain UTF-8 text, exactly what the buffer holds — no header, no JSON wrapper, no stored results. The file is the sheet, so it diffs, greps and opens in any editor.

Use Quickshell's file IO for this — a `FileView` bound to the path, written through its adapter. Write on a 400ms debounce after the last keystroke, and again when the panel hides. There is no shutdown hook worth relying on inside a shell process, so the debounce is the real guarantee: keep it short and never skip the write on hide.

If the file IO available to a plugin cannot write atomically, write to `sheet.calc.tmp` and rename over the target, so an interrupted write cannot leave a truncated sheet.

Read once when the plugin loads. A missing file means an empty sheet, which is not an error. A file that fails to read — permissions, bad UTF-8 — starts empty and logs a line; never show a file error in the UI, and never overwrite a file you could not read. Bear in mind a log line from a plugin lands in the shell's log, so keep it identifiable and rare.

The cursor position is not persisted. Reopening puts the cursor at the end of the sheet, which is where you were going anyway.

## Currency rates

The prototype ships placeholder rates and labels every currency result `rate` in `warn` to say so. Replace them with real ones; do not ship the placeholders.

Any free daily-rates endpoint works — the ECB reference rates, or an aggregator that serves them as JSON. Requirements rather than a choice of vendor:

- Euro-based, matching the engine's internal base.
- No API key, or a key the user supplies — never one committed to the repo.
- Daily granularity is plenty. Intraday rates would imply a precision this app should not claim.

Cache to `~/.cache/omasum/rates.json`: the fetch date, the base currency, and a map of code to rate. Refresh when the cache is older than 24 hours and when the plugin loads, never on a keystroke. Fetch asynchronously — QML's `XMLHttpRequest`, or a `Process` running `curl` if the endpoint needs anything awkward. Since a plugin shares the shell's process, a blocking fetch would freeze the bar and every menu, not just this panel: that makes async a hard requirement here rather than good practice.

When the cache is stale or absent:

1. **Stale cache present** — use it, and mark every currency result `rate` in `warn` with the cache's age available on hover. A rate from Tuesday is almost always fine; silently pretending it is today's is not.
2. **No cache at all** — currency conversion fails on that line with `rates unavailable`. Do not fall back to invented numbers, and do not fail any other conversion; length, mass and the rest need no network.

Currency results round to the same magnitude rule as everything else. Do not special-case two decimals: the sheet is arithmetic, not an invoice, and a rate multiplied out to four places is often what the next line needs.

## Summoning it

No daemon, no socket, no service unit, no window rules. The shell is already running and already owns its surfaces; a panel plugin is toggled over the shell's IPC.

The shell exposes a `toggle` method taking a plugin id and an optional JSON payload. Either form works:

```
omarchy-shell shell toggle dev.nur.omasum
quickshell ipc -p $OMARCHY_PATH/shell call shell toggle dev.nur.omasum
```

The first is the convenience wrapper; the second is what it wraps. Use the wrapper in the keybind and the README. A payload is only needed if the panel ever takes arguments — the documented example is `omarchy-shell shell toggle omarchy.menu '{"menu":"root"}'` — and this one does not.

**Keybind: `SUPER + SHIFT + Q`.** Omarchy 4 writes Hyprland configuration in Lua, so a user binding goes in `~/.config/hypr/bindings.lua`, not a `.conf` file. The old `bindings.conf` is left on disk by the upgrade but is no longer loaded, which is the single most likely way this install instruction goes wrong for someone. Say so in the README.

```lua
o.bind('SUPER + SHIFT + Q', 'Omasum', 'omarchy-shell shell toggle dev.nur.omasum')
```

The signature is key combination, a label shown in the keybind list, then the command. Upstream's own examples use double quotes; single quotes are equally valid Lua and avoid escaping trouble when this line is pasted through a shell. The label matters more than it looks: Omarchy 4 surfaces bindings in its own keybind viewer, so `Omasum` is what the user will see there.

Check `SUPER + SHIFT + Q` against the stock bindings before the README recommends it. Omarchy 4's defaults are not in `bindings.lua` — that file holds only the user's own — so read them from the keybind viewer or the package's config, and pick something else if it collides.

## Installing and sharing

No package to build. The repo *is* the plugin: clone or symlink it into `~/.config/omarchy/plugins/omasum`, run `omarchy plugin validate ./omasum`, then `omarchy plugin enable dev.nur.omasum`. Nothing is compiled, so there is no build step and no toolchain to keep in step with.

A README with four lines — clone, validate, enable, add the bind — is the whole install story. Ship the `o.bind` line as text for the user to paste into `~/.config/hypr/bindings.lua`; a plugin that edits someone's keybind file is a plugin that breaks it.

Make the README's first line say what Omasum is, in one sentence, before anything else. The name is `oma` plus `sum`, in the family of Omarchy's own apps — but it is also the third chamber of a cow's stomach, so searching for it does not explain the tool. One plain sentence up front fixes that.

If you later want it installable with `pacman`, a PKGBUILD that drops the same directory into place is easy to add, and nothing above needs to change for it. Worth doing only if other people start using it.

## Engine test vectors

One line in, one display string out, against an empty scope unless stated. Write these as tests against `engine.js` under `node --test` before building any QML — they are the specification of correct, and every one was computed from the formatting rule above rather than copied from a screenshot.

| Input | Display | Tests |
| --- | --- | --- |
| `2 + 3 * (4 - 1)^2` | `29` | Precedence, right-associative power |
| `2^-1` | `0.5` | Unary minus after an operator |
| `3(4+1)` | `15` | Implicit multiplication into a group |
| `2pi` | `6.2832` | Implicit multiplication into a constant |
| `sqrt(2) * 10` | `14.1421` | 4 decimals in 1..100 |
| `1_000_000 / 7` | `142 857.14` | Underscore separator, 2 decimals at 100+, thin space |
| `1,000 + 1` | `1 001` | Comma as a group separator |
| `min(1,2)` | `1` | Comma as an argument separator |
| `10 % 3` | `1` | Modulo, not percent |
| `0xff + 1` | `256` | Hex literal |
| `0b1010 * 2` | `20` | Binary literal |
| `18% of 240` | `43.2` | Percent of |
| `240 + 18%` | `283.2` | Percent added |
| `1450 - 7%` | `1 348.5` | Percent subtracted |
| `84 as % of 400` | `21 %` | Ratio as percent, with the suffix |
| `20 km to miles` | `12.4274 mi` | Plural alias, length |
| `5 in to cm` | `12.7 cm` | Last separator wins where `in` is also a unit |
| `92 f to c` | `33.3333 °C` | Temperature offset, not factor |
| `100 c to f` | `212 °F` | Temperature the other way |
| `2.5 GB to MiB` | `2 384.19 MiB` | Decimal and binary data units are distinct |
| `90 min in h` | `1.5 h` | `in` as a separator |
| `75 kg to lbs` | `165.35 lb` | 2 decimals at 100+, mass alias |
| `255 to hex` | `0xFF` | Base out |
| `12 to bin` | `0b1100` | Base out |

With scope, to test that units and values survive a binding:

| Scope | Input | Display |
| --- | --- | --- |
| `rate = 65 eur` | `rate` | `65 EUR` |
| `leg = 18 km` | `leg * 2 * 21 to miles` | `469.76 mi` |
| `hours = 38`, `rate = 65 eur` | `hours * rate` | `2 470 EUR` |
| previous line gave `2470 EUR` | `ans / 3` | `823.33 EUR` |

Errors, asserting the exact message:

| Input | Message |
| --- | --- |
| `hours * rat` | `rat is not defined` |
| `12 km to kg` | `can't convert km to kg` |
| `12 km to kgg` | `kgg is not a unit` |
| `240 to eur` | `no unit to convert from` |
| `2 +` | `unfinished line` |
| `(2 + 3` | `missing )` |

Sheet-level, which is where propagation gets tested:

1. `rent = 1450` / `utils = 190` / `total = rent + utils` / `total * 12` gives 1 450, 190, 1 640, 19 680. Change line one to `1600` and the same four lines give 1 600, 190, 1 790, 21 480 with no other edit.
2. `# just a note` gives no result and no error. `rate = 65 eur   # agreed 12 Feb` gives `65 EUR`.
3. A line using a name defined *below* it errors with `is not defined`, and the line defining it still works.
4. A sheet whose third line is `hours * rat` still shows results for lines one, two and four.

One known discrepancy: the `Syntax` artboard shows `75 kg to lbs` as `165.3467 lb`, which predates the rounding rule. The rule in this document is authoritative — `165.35 lb`. Trust the vectors over the mockups wherever they disagree.

## Build order, non-goals, open questions

Build it in this order. Each milestone is worth committing and each one is checkable without the next.

1. **`engine.js` alone.** Lexer, parser, units, formatting, the sheet evaluator. Every test vector above passing under `node --test`, with no QML in the repo yet. This is the bulk of the work and the only part where correctness is hard.
2. **A panel that opens.** `manifest.json`, an `Omasum.qml` that shows an empty window at the right size, validated and enabled, toggling on the keybind. Prove the plumbing before putting anything in the window.
3. **The sheet, hard-coded colours.** `TextEdit` plus the coloured `Text` behind it, the result column beside it, correct metrics. It should behave like the prototype by the end of this step.
4. **Theme binding.** Tokens from `Color` and `Style`, derived `accent2`, the contrast guard. Switch to a light theme early — that is what catches assumptions.
5. **Persistence**, then **rates**, then the README and the bind line.

Explicit non-goals for the first cut. Each was considered and left out on purpose:

- Named or multiple sheets. One sheet until one sheet is proven annoying.
- Soft-wrapping long lines. They clip, which keeps the gutter aligned. Revisit only if it bites in real use.
- Date and time arithmetic. A real want, but it needs its own grammar design.
- Unit algebra — `60 km / 2 h` yielding km/h. The current model tags an expression with one unit and does not divide dimensions. Do not half-build it.
- A settings UI. The theme comes from the system; there is nothing else to configure.
- Plotting, tables, a function-definition syntax, sheet export.

Open questions, none of them blocking:

- Whether `SUPER + SHIFT + Q` collides with an Omarchy 4 default. Check the keybind viewer before the README recommends it.
- The exact `Color` and `Style` property names, and which surface roles to map our tokens onto. Read them off a first-party plugin rather than guessing.
- How a panel plugin declares its size and gets centred, and whether it takes keyboard focus on demand. The OSD plugin is the example to copy.
- Whether a plugin's file IO can write atomically, which decides if the autosave needs the tmp-and-rename dance.
- Whether `TextEdit`'s undo covers a programmatic clear, which decides if Clean sheet needs its own one-step undo.
- Which rates endpoint. Any euro-based daily source meets the spec; pick one you are happy to depend on.
- Whether living in the shell process brings a plugin reload story worth using while developing, or whether it means restarting the shell on every edit. Worth finding out on day one, since it sets the whole inner loop.

The design canvas stays the visual reference — `Sheet — live` for behaviour, `Theme tokens` for the palette across seven themes, `States` for the four states, `System theme` for how different a light theme looks. Where a mockup and this document disagree on a number, this document wins.
