import { Controller } from "@hotwired/stimulus"

// Holds the submit button until every gated field has been retyped: the
// connection name (case-insensitive: the chip shows it uppercase, so PROD must
// count) and, on a delete, the entity's own name (exact, the way the server
// compares it). Each input carries its expected text in data-expected, and
// data-exact marks the ones that must match to the letter.
// Progressive enhancement only: the server re-checks every name on apply, so a
// page without JS still works -- it just fails with an alert instead.
export default class extends Controller {
  static targets = ["input", "submit", "hint"]

  connect() {
    this.check()
  }

  check() {
    const unlocked = this.inputTargets.every((input) => this.matches(input))
    this.submitTarget.disabled = !unlocked

    if (!this.hasHintTarget) return
    // The hint only explains why the button is disabled; once it is not, it has
    // nothing left to say to the eye or to a screen reader.
    this.hintTarget.hidden = unlocked
    if (unlocked) this.submitTarget.removeAttribute("aria-describedby")
    else this.submitTarget.setAttribute("aria-describedby", this.hintTarget.id)
  }

  matches(input) {
    const expected = input.dataset.expected ?? ""
    if ("exact" in input.dataset) return input.value === expected
    return input.value.trim().toLowerCase() === expected.toLowerCase()
  }
}
