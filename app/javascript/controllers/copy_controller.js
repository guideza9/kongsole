import { Controller } from "@hotwired/stimulus"

// R8.9: copies a block of text (the PR description) for pasting into the git
// host, and says so in a polite live region. Without JS, or where the
// clipboard is refused, the text stays selectable in its own box.
export default class extends Controller {
  static targets = ["source", "status"]
  static values = { done: String, failed: String }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.textContent)
      this.say(this.doneValue)
    } catch {
      this.select()
      this.say(this.failedValue)
    }
  }

  select() {
    const range = document.createRange()
    range.selectNodeContents(this.sourceTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }

  say(text) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = ""
    requestAnimationFrame(() => { this.statusTarget.textContent = text })
  }
}
