require "rails_helper"

RSpec.describe ProjectNotes do
  let(:dir) { Pathname(Dir.mktmpdir) }
  let(:project) { create(:project, key: "project-a") }

  it "renders the project's markdown, Thai included" do
    File.write(dir.join("project-a.md"), "# Billing flow\n\nOwner: **Team A** — ทุกการชำระเงินผ่าน billing ก่อน")
    html = described_class.new(project, dir: dir).html
    expect(html).to include("<h1>Billing flow</h1>", "<strong>Team A</strong>", "ทุกการชำระเงินผ่าน billing ก่อน")
    expect(html).to be_html_safe
  end

  it "drops raw HTML and javascript: links" do
    File.write(dir.join("project-a.md"), "<script>alert(1)</script>\n\n[x](javascript:alert(1)) [y](https://wiki.example/y) [z](mailto:a@b.example)")
    html = described_class.new(project, dir: dir).html
    expect(html).not_to include("<script>")
    expect(html).not_to include("javascript:")
    expect(html).to include('href="https://wiki.example/y"', 'href="mailto:a@b.example"')
  end

  it "returns nil when the project has no notes yet" do
    expect(described_class.new(create(:project, key: "project-x"), dir: dir).html).to be_nil
  end

  it "names the file relative to the repo" do
    expect(described_class.new(project).relative_path).to eq("config/projects/project-a.md")
  end
end
