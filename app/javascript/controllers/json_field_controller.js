import { Controller } from "@hotwired/stimulus"

// R4.7: a nested config field typed as JSON (a record, a map, a list of
// records). Checks it as it is typed, the way the whole-plugin editor
// (json_editor_controller.js) checks its document, and says so beside the
// field; the server checks again (Kong::PluginFormParams). Empty is fine:
// a blank field sends the schema's default.
export default class extends Controller {
  static targets = ["input", "status"]

  check() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.report(), 200)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }

  report() {
    const value = this.inputTarget.value
    if (value.trim() === "") return this.show("", null)

    try {
      JSON.parse(value)
      this.show("Valid JSON", true)
    } catch (error) {
      const position = /position (\d+)/.exec(error.message)
      const where = position ? ` near character ${Number(position[1]) + 1}` : ""
      this.show(`Not valid JSON${where} -- check the brackets, quotes and commas.`, false)
    }
  }

  show(message, valid) {
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("is-invalid", valid === false)
    if (valid === false) {
      this.inputTarget.setAttribute("aria-invalid", "true")
    } else {
      this.inputTarget.removeAttribute("aria-invalid")
    }
  }
}
