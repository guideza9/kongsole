# Writes a request spec's rendered page to tmp/ui-snapshots/<name>.html for
# `npx impeccable detect`, which scans HTML and cannot read .erb. The local
# stylesheet links are swapped for the built Tailwind CSS inline, so the
# snapshot carries its styles without a running server.
module UiSnapshots
  DIR = Rails.root.join("tmp", "ui-snapshots")
  TAILWIND = Rails.root.join("app", "assets", "builds", "tailwind.css")
  LOCAL_STYLESHEET = %r{<link[^>]*rel="stylesheet"[^>]*href="/assets/[^"]*"[^>]*>\s*}

  # Writes only when UI_SNAPSHOTS=1, so the ordinary suite stays side-effect
  # free; `force: true` is for this helper's own spec. Returns the path, or
  # nil when nothing was written.
  def snapshot!(name, force: false)
    expect(response).to have_http_status(:ok)
    return unless force || ENV["UI_SNAPSHOTS"] == "1"

    FileUtils.mkdir_p(DIR)
    path = DIR.join("#{name}.html")
    File.write(path, inline_stylesheets(response.body))
    path
  end

  private

  def inline_stylesheets(html)
    style = "<style>#{File.read(TAILWIND)}</style>\n"
    first = true
    html.gsub(LOCAL_STYLESHEET) do
      next "" unless first

      first = false
      style
    end
  end
end
