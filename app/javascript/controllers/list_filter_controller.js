import { Controller } from "@hotwired/stimulus"

// R4.6: narrows a list as the filter is typed -- the plugin catalog's rows,
// the scope picker's options. Every word must appear in an item's
// data-filter-text. A group whose items are all hidden hides too, and the
// count and "none" line say what is left. The filter itself stays hidden
// until this connects: without JS every item is on the page and nothing
// pretends to filter it.
export default class extends Controller {
  static targets = ["field", "input", "item", "group", "count", "none"]

  connect() {
    if (this.hasFieldTarget) this.fieldTarget.hidden = false
  }

  filter() {
    const terms = this.inputTarget.value.toLowerCase().split(/\s+/).filter(Boolean)
    let shown = 0

    this.itemTargets.forEach((item) => {
      const text = item.dataset.filterText || ""
      const found = terms.every((term) => text.includes(term))
      item.hidden = !found
      if (item.tagName === "OPTION") item.disabled = !found
      if (found) shown++
    })

    this.groupTargets.forEach((group) => {
      group.hidden = !this.itemTargets.some((item) => group.contains(item) && !item.hidden)
    })

    if (this.hasCountTarget) {
      this.countTarget.textContent = terms.length ? `${shown} of ${this.itemTargets.length} shown` : ""
    }
    if (this.hasNoneTarget) this.noneTarget.hidden = shown > 0
  }
}
