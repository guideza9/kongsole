import { Controller } from "@hotwired/stimulus"

// Announces a flash banner to screen readers.
//
// The banner carries role="status" (or role="alert" for an error), but a live
// region only reports what changes *after* it exists. A flash arrives with the
// page it belongs to -- region and text parsed in the same breath -- so on a
// redirect there is no change to report and the message goes unheard, even
// though it is the one thing the redirect was for.
//
// So the text is lifted out and put back a frame later: by then the region is
// established and empty, and re-inserting the message is a change. The banner
// is server-rendered complete, so with JS off nothing is removed and the
// message still stands. Sighted readers see no gap either: the frame callback
// runs before the next paint, so the emptied banner is never painted.
export default class extends Controller {
  connect() {
    const message = this.element.innerHTML
    if (!message.trim()) return

    this.element.innerHTML = ""
    this.frame = requestAnimationFrame(() => {
      this.element.innerHTML = message
    })
  }

  // Turbo can tear the page down mid-frame (a fast second navigation, or a
  // cached preview being swapped out). Restoring the text into a detached
  // element would be harmless but pointless; dropping the callback keeps the
  // banner from being rebuilt after its page is gone.
  disconnect() {
    cancelAnimationFrame(this.frame)
  }
}
