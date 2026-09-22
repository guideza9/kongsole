import { Controller } from "@hotwired/stimulus"

// Live JSON validation *and* syntax highlighting for the full-document
// entity editor.
//
// A <textarea> can't hold colored spans, so the highlighted copy renders
// into a <pre> sitting exactly beneath it (see .json-editor in
// application.css); the textarea's own text is transparent, so the
// highlighted copy shows through right where the cursor is. The two must
// stay pixel-identical (font, padding, line-height) and scroll together,
// or the illusion breaks the moment the document scrolls. Forced-colors mode
// overrides that transparent and would double the text, so the stylesheet
// drops the overlay there and the textarea stands alone.
//
// Validation is still server-checked too (EntitiesController::InvalidPayload)
// -- this only saves the operator a round trip, and never lets a submit go
// out on JSON already known to be broken.
const JSON_TOKEN = /("(?:\\u[0-9a-fA-F]{4}|\\[^u]|[^\\"])*"(\s*:)?)|\btrue\b|\bfalse\b|\bnull\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g

export default class extends Controller {
  static targets = ["wrapper", "highlight", "input", "status", "submit"]

  connect() {
    this.renderHighlight()
    this.validate()
  }

  // Highlighting is cheap (one regex pass) and runs on every keystroke, so
  // the colored copy never lags a character behind what's being typed.
  // Validation reparses the whole document and only needs to settle once
  // typing pauses, so it stays debounced separately.
  validate() {
    this.renderHighlight()
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.check(), 200)
  }

  renderHighlight() {
    this.highlightTarget.innerHTML = this.highlight(this.inputTarget.value)
  }

  // Escaping the whole string before tokenizing (rather than only the
  // matched tokens, the read-only viewer's approach in
  // ApplicationHelper#highlight_json) matters here specifically because
  // this text isn't guaranteed-valid Kong JSON yet -- it's whatever the
  // operator has typed so far, including a stray "<" sitting outside any
  // quoted string mid-edit.
  highlight(raw) {
    const escaped = raw.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    return escaped.replace(JSON_TOKEN, (token) => `<span class="${this.tokenClass(token)}">${token}</span>`)
  }

  tokenClass(token) {
    if (token.startsWith("\"")) return token.endsWith(":") ? "json-key" : "json-string"
    if (token === "true" || token === "false") return "json-bool"
    if (token === "null") return "json-null"
    return "json-number"
  }

  syncScroll() {
    this.highlightTarget.scrollTop = this.inputTarget.scrollTop
    this.highlightTarget.scrollLeft = this.inputTarget.scrollLeft
  }

  // Parsed raw rather than trimmed: JSON.parse ignores surrounding whitespace
  // anyway, and the line and column it reports then count from the same first
  // character the operator sees in the textarea.
  check() {
    const value = this.inputTarget.value

    if (value.trim() === "") {
      return this.report("The document can't be empty.", false)
    }

    try {
      const parsed = JSON.parse(value)
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        return this.report("The JSON must be an object, not an array or a single value.", false)
      }
      return this.report(`Valid JSON · ${Object.keys(parsed).length} fields`, true)
    } catch (error) {
      return this.report(this.plainError(error, value), false)
    }
  }

  // Browsers phrase a parse failure for whoever wrote the parser, and each one
  // phrases it differently: "Unexpected token } in JSON at position 214",
  // "JSON.parse: expected ',' or '}' after property value in object at line 7
  // column 3". The useful part is where the parser stopped and what it wanted
  // there; the rest is vocabulary an operator editing a Kong entity should not
  // have to learn. So the message is rebuilt in the app's own words: what is
  // wrong, and which line and column to look at.
  plainError(error, value) {
    const original = String(error?.message ?? "")
    const spot = this.errorSpot(original, value)
    const at = spot ? ` at line ${spot.line}, column ${spot.column}` : ""

    if (/end of (?:json )?(?:input|data)/i.test(original)) {
      return "The document ends early — a brace, bracket or quote opened earlier is never closed."
    }
    if (/unterminated string/i.test(original)) {
      return `A quoted value is never closed${at}.`
    }
    // Ordered before the field-name test: "Expected ':' after property name"
    // mentions a property name but is really a missing colon, and reading it
    // as a name problem would send the operator to the wrong character.
    if (/expected ['"`]?:|after property name/i.test(original)) {
      return `A colon is missing between a field name and its value${at}.`
    }
    if (/property name/i.test(original)) {
      return `A field name is missing, or missing its quotes${at}.`
    }
    if (/expected ['"`]?[,}\]]|after (?:property value|array element)/i.test(original)) {
      return `A comma or a closing bracket is missing${at}.`
    }
    if (/unexpected (?:token|character|non-whitespace)/i.test(original) && at) {
      return `A character JSON doesn't allow${at}.`
    }
    return at
      ? `This isn't valid JSON yet — the problem starts${at}.`
      : "This isn't valid JSON yet — check for a missing comma, quote or bracket."
  }

  // Firefox names the line and column outright; Chrome and Safari give a
  // character offset (and newer Chrome both). Either way the offset counts
  // from the start of the string handed to JSON.parse, which is the textarea's
  // own text, so counting newlines up to it lands on the line being edited.
  errorSpot(message, value) {
    const named = message.match(/line (\d+) column (\d+)/i)
    if (named) return { line: Number(named[1]), column: Number(named[2]) }

    const offset = message.match(/position (\d+)/i)
    if (!offset) return null

    const before = value.slice(0, Number(offset[1])).split("\n")
    return { line: before.length, column: before[before.length - 1].length + 1 }
  }

  format() {
    try {
      this.inputTarget.value = JSON.stringify(JSON.parse(this.inputTarget.value), null, 2)
      this.renderHighlight()
      this.check()
    } catch {
      // Unparseable input has no formatting to apply; the status line is
      // already saying why.
    }
  }

  report(message, valid) {
    // The status line is a live region: only touch it when the message
    // actually changes, so re-validating unchanged text does not re-announce it.
    if (this.statusTarget.textContent !== message) this.statusTarget.textContent = message
    this.statusTarget.style.color = valid ? "var(--color-ink-faint)" : "var(--color-danger)"
    this.submitTarget.disabled = !valid
    this.submitTarget.style.opacity = valid ? "" : "0.5"
    this.wrapperTarget.classList.toggle("json-editor--invalid", !valid)
  }
}
