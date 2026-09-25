import { Controller } from "@hotwired/stimulus"

// R2.5: the service form. The port follows the protocol (80 / 443) until the
// operator types one of their own, and a line under the fields spells out
// the URL Kong will forward to -- the server still checks and builds it.
export default class extends Controller {
  static targets = ["protocol", "host", "port", "path", "target", "url"]
  static values = { ports: Object }

  connect() {
    const defaultPort = String(this.portsValue[this.protocolTarget.value] ?? "")
    this.portEditedByHand = this.portTarget.value !== "" && this.portTarget.value !== defaultPort
    this.preview()
  }

  protocolChanged() {
    if (!this.portEditedByHand) this.portTarget.value = this.portsValue[this.protocolTarget.value] ?? ""
    this.preview()
  }

  portEdited() {
    this.portEditedByHand = this.portTarget.value !== ""
    this.preview()
  }

  preview() {
    const host = this.hostTarget.value.trim()
    this.targetTarget.hidden = host === ""
    if (host === "") return

    const port = this.portTarget.value.trim() || this.portsValue[this.protocolTarget.value]
    const path = this.pathTarget.value.trim()
    this.urlTarget.textContent = `${this.protocolTarget.value}://${host}:${port}${path}`
  }
}
