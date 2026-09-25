import { Controller } from "@hotwired/stimulus"

// R1.19: narrows the connections page as the filter is typed, with the rule
// ProjectFilter applies on the server for ?q= -- every word must appear in the
// project's name or key, or in one of its env names; the envs a word named
// stay bright and the project's others dim. Live only when the whole list is
// on the page (no ?q=); otherwise Filter submits and the server narrows it.
export default class extends Controller {
  static targets = ["input", "row", "none"]
  static values = { live: Boolean }

  filter() {
    if (!this.liveValue) return

    const terms = this.inputTarget.value.toLowerCase().split(/\s+/).filter(Boolean)
    let shown = 0

    this.rowTargets.forEach((row) => {
      const envs = [...row.querySelectorAll(".launcher__env")]
      const named = new Set()
      const found = terms.every((term) => {
        const hits = envs.filter((env) => env.dataset.envName.includes(term))
        hits.forEach((env) => named.add(env))
        return row.dataset.filterText.includes(term) || hits.length > 0
      })

      row.hidden = !found
      if (found) shown++
      envs.forEach((env) => env.classList.toggle("is-dim", named.size > 0 && !named.has(env)))
    })

    if (this.hasNoneTarget) this.noneTarget.hidden = shown > 0
  }
}
