import { Controller } from "@hotwired/stimulus"

// R2.6: the route form, as it is typed. Shows what the route will take as a
// request line (the same .route-match mark the lists use), and 300ms after
// the last change asks the server which routes it would compete with
// (GET routes/overlap -- read-model only). The answer lands in a polite live
// region: a warning to read, never a block. The server re-checks on review.
export default class extends Controller {
  static targets = ["method", "hosts", "paths", "preview", "line", "list"]
  static values = { url: String, reasons: Object, title: String, none: String }

  connect() {
    this.render()
    if (this.hasRules()) this.check()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.request?.abort()
  }

  changed() {
    this.render()
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.check(), 300)
  }

  rules() {
    const lines = (target) => target.value.split(/\r?\n/).map((line) => line.trim()).filter((line) => line !== "")
    return {
      methods: this.methodTargets.filter((box) => box.checked).map((box) => box.value),
      hosts: lines(this.hostsTarget),
      paths: lines(this.pathsTarget)
    }
  }

  hasRules() {
    const { methods, hosts, paths } = this.rules()
    return methods.length + hosts.length + paths.length > 0
  }

  // The request line: methods (ANY when none), then hosts, then paths with a
  // regex's ~ marked -- built as text nodes, never HTML.
  render() {
    const { methods, hosts, paths } = this.rules()
    this.previewTarget.hidden = !this.hasRules()
    this.lineTarget.replaceChildren(this.requestLine(methods, hosts, paths))
  }

  requestLine(methods, hosts, paths) {
    const line = this.span("route-match route-panel__line")
    const methodsBox = this.span("route-match__methods")
    if (methods.length === 0) methodsBox.append(this.span("route-method route-method--any", "ANY"))
    methods.forEach((method) => methodsBox.append(this.span("route-method", method)))

    const where = this.span("route-match__where")
    hosts.forEach((host) => where.append(this.span("route-host", host)))
    paths.forEach((path) => {
      const mark = this.span("route-path")
      if (path.startsWith("~")) {
        const tilde = this.span("route-path__regex", "~")
        tilde.title = "Regular expression"
        mark.append(tilde, path.slice(1))
      } else {
        mark.append(path)
      }
      where.append(mark)
    })
    if (hosts.length === 0 && paths.length === 0) where.append(this.span("route-path route-path--open", "every path"))
    line.append(methodsBox, where)
    return line
  }

  async check() {
    this.request?.abort()
    if (!this.hasRules()) {
      this.listTarget.replaceChildren()
      return
    }

    const { methods, hosts, paths } = this.rules()
    const query = new URLSearchParams()
    methods.forEach((value) => query.append("methods[]", value))
    hosts.forEach((value) => query.append("hosts[]", value))
    paths.forEach((value) => query.append("paths[]", value))

    this.request = new AbortController()
    try {
      const response = await fetch(`${this.urlValue}?${query}`, {
        headers: { Accept: "application/json" }, signal: this.request.signal
      })
      if (!response.ok) return this.listTarget.replaceChildren()
      const { overlaps } = await response.json()
      this.show(overlaps)
    } catch (error) {
      // Aborted by a newer check, or offline: the review page checks again.
      if (error.name !== "AbortError") this.listTarget.replaceChildren()
    }
  }

  show(overlaps) {
    if (overlaps.length === 0) {
      const none = document.createElement("p")
      none.className = "route-overlaps-live__none"
      none.textContent = this.noneValue
      this.listTarget.replaceChildren(none)
      return
    }

    const box = document.createElement("div")
    box.className = "notice-banner notice-banner--warning risk-notice"
    const title = document.createElement("p")
    title.className = "risk-notice__title"
    title.textContent = this.titleValue
    const list = document.createElement("ul")
    list.className = "route-overlaps"
    overlaps.forEach((overlap) => {
      const item = document.createElement("li")
      item.className = "route-overlaps__item"
      item.append(this.span("route-overlaps__name", overlap.route_name ?? ""))
      if (overlap.service_name) item.append(this.span("route-overlaps__service", `on ${overlap.service_name}`))
      item.append(this.span(`route-overlaps__reason route-overlaps__reason--${overlap.reason}`,
        this.reasonsValue[overlap.reason] ?? overlap.reason))
      list.append(item)
    })
    box.append(title, list)
    this.listTarget.replaceChildren(box)
  }

  span(className, text) {
    const element = document.createElement("span")
    element.className = className
    if (text !== undefined) element.textContent = text
    return element
  }
}
