# R5.5: the notes a team writes about a project -- business flow, owners,
# who to call, what to be careful of -- kept in this repo at
# config/projects/<key>.md so everyone reads the same ones and changes go
# through a pull request. Rendered without raw HTML; links only http(s)/mailto.
class ProjectNotes
  DIR = Rails.root.join("config/projects")
  SAFE_SCHEMES = %w[http https mailto].freeze
  HEADINGS = [ "Business flow", "Owners", "Who to contact", "Before you change anything" ].freeze

  def self.skeleton(project)
    "# #{project.name}\n\n" + HEADINGS.map { "## #{_1}\n\n" }.join
  end

  def initialize(project, dir: DIR)
    @project = project
    @dir = Pathname(dir)
  end

  def relative_path
    "config/projects/#{@project.key}.md"
  end

  def path
    raise ArgumentError, "unsafe project key" unless @project.key.match?(Project::KEY_FORMAT)

    @dir.join("#{@project.key}.md")
  end

  def html
    return nil unless path.file?

    # header_ids off: Commonmarker 2 adds heading anchors by default.
    markup = Commonmarker.to_html(path.read, options: { render: { unsafe: false }, extension: { header_ids: nil } })
    fragment = Nokogiri::HTML5.fragment(markup)
    fragment.css("[href]").each do |node|
      scheme = node["href"].to_s.strip[/\A([a-z][a-z0-9+.-]*):/i, 1]&.downcase
      node.remove_attribute("href") unless scheme && SAFE_SCHEMES.include?(scheme)
    end
    fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety -- unsafe HTML dropped above
  end
end
