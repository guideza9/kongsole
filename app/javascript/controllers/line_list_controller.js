import { Controller } from "@hotwired/stimulus"

// A list of values, one row each, with "Add <noun>" and "Remove" -- in place
// of a textarea where "one per line" had to be read to be discovered. The
// textarea stays the form's field (hidden, kept in sync), so the server gets
// the same newline list with or without JS, and anything listening to the
// textarea's input event (route-overlap) still hears every change.
export default class extends Controller {
  static targets = ["source", "rows", "add"]
  static values = { noun: String, placeholder: String }

  connect() {
    const values = this.sourceTarget.value.split(/\r?\n/).map((line) => line.trim()).filter((line) => line !== "")
    this.sourceTarget.hidden = true
    this.addTarget.hidden = false
    this.rowsTarget.replaceChildren(...(values.length ? values : [""]).map((value) => this.row(value)))
    this.renumber()
  }

  disconnect() {
    this.sourceTarget.hidden = false
  }

  // From the Add button: an empty row already there is used, not a new one.
  add(event) {
    const after = event?.currentTarget?.closest?.(".line-list__row")
    const empty = !after && this.inputs().find((input) => input.value.trim() === "")
    if (empty) return empty.focus()

    const row = this.row("")
    if (after) after.after(row)
    else this.rowsTarget.append(row)
    this.renumber()
    row.querySelector("input").focus()
  }

  remove(event) {
    const row = event.currentTarget.closest(".line-list__row")
    const previous = row.previousElementSibling || row.nextElementSibling
    row.remove()
    this.renumber()
    this.sync()
    previous?.querySelector("input")?.focus()
  }

  // Enter adds the next row instead of sending the form; Backspace in an
  // empty row (not the only one) takes it away.
  key(event) {
    const input = event.currentTarget
    if (event.key === "Enter") {
      event.preventDefault()
      this.add({ currentTarget: input })
    } else if (event.key === "Backspace" && input.value === "" && this.inputs().length > 1) {
      event.preventDefault()
      this.remove({ currentTarget: input })
    }
  }

  sync() {
    this.sourceTarget.value = this.inputs().map((input) => input.value.trim()).filter((value) => value !== "").join("\n")
    this.sourceTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  inputs() {
    return Array.from(this.rowsTarget.querySelectorAll("input"))
  }

  row(value) {
    const row = document.createElement("div")
    row.className = "line-list__row"

    const input = document.createElement("input")
    input.type = "text"
    input.value = value
    input.className = "field-input font-mono"
    input.autocapitalize = "off"
    input.spellcheck = false
    input.setAttribute("autocomplete", "off")
    for (const name of ["aria-describedby", "aria-invalid"]) {
      const current = this.sourceTarget.getAttribute(name)
      if (current) input.setAttribute(name, current)
    }
    input.dataset.action = "input->line-list#sync keydown->line-list#key"

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "btn-sm btn-text line-list__remove"
    remove.textContent = "Remove"
    remove.dataset.action = "line-list#remove"

    row.append(input, remove)
    return row
  }

  // Row labels and ids follow the order; the field's label points at the
  // first row; a lone row has nothing to remove.
  renumber() {
    const rows = Array.from(this.rowsTarget.children)
    const noun = this.nounValue
    rows.forEach((row, index) => {
      const input = row.querySelector("input")
      const remove = row.querySelector("button")
      input.id = `${this.sourceTarget.id}_${index}`
      input.setAttribute("aria-label", `${noun.charAt(0).toUpperCase()}${noun.slice(1)} ${index + 1}`)
      input.placeholder = index === 0 ? this.placeholderValue : ""
      remove.hidden = rows.length === 1
      remove.setAttribute("aria-label", `Remove ${noun} ${index + 1}`)
    })
    const label = this.element.querySelector(`label[for="${this.sourceTarget.id}"], label[data-line-list-label]`)
    if (label && rows[0]) {
      label.dataset.lineListLabel = ""
      label.htmlFor = rows[0].querySelector("input").id
    }
  }
}
