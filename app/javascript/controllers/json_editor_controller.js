import { Controller } from "@hotwired/stimulus"

// Live JSON validation *and* syntax highlighting for the full-document
// entity editor.
//
// A <textarea> can't hold colored spans, so the highlighted copy renders
// into a <pre> sitting exactly beneath it (see .json-editor in
// application.css); the textarea's own text is transparent, so the
// highlighted copy shows through right where the cursor is. The two must
// stay pixel-identical (font, padding, line-height) and scroll together,
// or the illusion breaks the moment the document scrolls.
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

  check() {
    const value = this.inputTarget.value.trim()

    if (value === "") {
      return this.report("The document can't be empty.", false)
    }

    try {
      const parsed = JSON.parse(value)
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        return this.report("The JSON must be an object, not an array or a single value.", false)
      }
      return this.report(`Valid JSON · ${Object.keys(parsed).length} fields`, true)
    } catch (error) {
      return this.report(error.message, false)
    }
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
