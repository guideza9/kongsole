import { Controller } from "@hotwired/stimulus"

// Absolute timestamps are server-rendered in UTC, because Rails has no way to
// know the browser's zone. This rewrites them in the viewer's own zone and
// names that zone, so "expires 14:05" can never be read an hour wrong by
// someone in a different office. The exact UTC instant stays in `title`, and
// with JS off the UTC text is what stands.
export default class extends Controller {
  connect() {
    const iso = this.element.getAttribute("datetime")
    if (!iso) return

    const parsed = new Date(iso)
    if (Number.isNaN(parsed.getTime())) return

    const local = this.format(parsed)
    if (local) this.element.textContent = local
  }

  // Assembled from parts rather than taken as a formatted string: every locale
  // punctuates a date differently ("21/09/2026, 19:21"), and that stray comma
  // lands mid-sentence in copy like "Pushed <time> to branch". Holding the
  // server's own YYYY-MM-DD HH:MM shape and swapping only the zone keeps the
  // timestamps on this page reading as one format.
  format(date) {
    try {
      const parts = new Intl.DateTimeFormat(undefined, {
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        hourCycle: "h23",
        timeZoneName: "short"
      }).formatToParts(date)

      const value = (type) => parts.find((part) => part.type === type)?.value
      const [ year, month, day, hour, minute, zone ] =
        [ "year", "month", "day", "hour", "minute", "timeZoneName" ].map(value)
      if (!year || !month || !day || !hour || !minute) return null

      return `${year}-${month}-${day} ${hour}:${minute}${zone ? ` ${zone}` : ""}`
    } catch {
      // No Intl, or a zone it cannot resolve -- the UTC text is already correct.
      return null
    }
  }
}
