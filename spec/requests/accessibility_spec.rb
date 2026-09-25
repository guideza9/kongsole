require "rails_helper"

# Accessibility hardening of the shared chrome and the forms/tables it frames:
# document language, live regions, current-page marking and label/id wiring.
RSpec.describe "Accessibility semantics", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def sign_in
    stub_request(:get, "https://kong-admin.test/")
      .to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice")
      .to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes")
      .to_return(status: 200, body: { data: [], offset: nil }.to_json)
    # Entity forms read Kong's schema for reference rows (R3.3); a 404 means hints only.
    stub_request(:get, %r{\Ahttps://kong-admin\.test/schemas/[a-z_]+\z})
      .to_return(status: 404, body: { message: "Not found" }.to_json)
    post login_connection_path(connection), params: { username: "alice", password: "pw" }
  end

  def page
    Nokogiri::HTML(response.body)
  end

  # Every <label> names a control that exists on the page, and no id repeats.
  def expect_labels_wired(doc)
    labels = doc.css("label")
    expect(labels).not_to be_empty
    labels.each do |label|
      target = label["for"]
      expect(target).to be_present, "label #{label.text.strip.inspect} has no for="
      expect(doc.css("[id='#{target}']").size).to eq(1), "label for=#{target.inspect} needs exactly one control"
    end
    ids = doc.css("[id]").map { |node| node["id"] }
    expect(ids.tally.select { |_, n| n > 1 }.keys).to be_empty
  end

  def nav_current(label)
    page.css("nav[aria-label='#{label}'] [aria-current]").map { |node| [ node.text.strip, node["aria-current"] ] }
  end

  describe "layout" do
    it "declares the document language" do
      get root_path

      expect(page.at_css("html")["lang"]).to eq("en")
    end

    it "opens with a skip link that reaches the main landmark" do
      get root_path

      first_link = page.at_css("body a")
      expect(first_link.text.strip).to eq("Skip to content")
      expect(first_link["href"]).to eq("#main")
      expect(page.at_css("main")["id"]).to eq("main")
      expect(page.at_css("main")["tabindex"]).to eq("-1")
    end

    # The banner ships complete so it still reads with JS off; the controller
    # is what re-inserts the text into the already-live region so a screen
    # reader hears it after a redirect.
    it "hands each flash banner to the announcing controller" do
      get entities_path # signed out: bounced with an alert
      follow_redirect!

      banner = page.at_css("main p.notice-banner[role='alert']")
      expect(banner["data-controller"]).to eq("flash")
      expect(banner.text).to include("Log into a connection first.")
    end

    it "announces an alert assertively" do
      get entities_path # signed out: bounced with an alert
      follow_redirect!

      expect(page.css("main p.notice-banner[role='alert']").map(&:text).join).to include("Log into a connection first.")
      expect(page.css("main p.notice-banner[role='status']")).to be_empty
    end

    it "announces a notice politely" do
      sign_in
      delete logout_path # redirects with a notice
      follow_redirect!

      expect(page.css("main p.notice-banner[role='status']").map(&:text).join).to include("Signed out.")
      expect(page.css("main p.notice-banner[role='alert']")).to be_empty
    end

    it "labels the primary nav and marks only the current section" do
      sign_in

      { entities_path => "Entities",
        entities_path(type: "route") => "Entities",
        expiring_certificates_path => "Entities",
        audit_events_path => "Audit",
        personal_access_tokens_path => "Tokens",
        health_path => "Health",
        connections_path => "Connections" }.each do |path, expected|
        get path

        expect(page.css("nav[aria-label='Primary']").size).to eq(1)
        expect(nav_current("Primary")).to eq([ [ expected, "page" ] ]), "for #{path}"
        expect(response.body).not_to include('aria-current="false"')
      end
    end

    it "keeps Connections current on the login form" do
      get login_connection_path(connection)

      expect(nav_current("Primary")).to eq([ [ "Connections", "page" ] ])
    end
  end

  describe "sessions/new" do
    it "ties each label to its input and the operator hint to its field" do
      get login_connection_path(connection)
      doc = page

      expect_labels_wired(doc)
      expect(doc.css("label").map { |l| l["for"] }).to contain_exactly("username", "password", "operator")
      expect(doc.at_css("input#operator")["aria-describedby"]).to eq("operator-hint")
      expect(doc.css("#operator-hint").size).to eq(1)
    end
  end

  describe "entities index" do
    before { sign_in }

    it "ties the filter labels to their controls and describes the tags field" do
      get entities_path
      doc = page

      expect_labels_wired(doc)
      expect(doc.css("form label").map { |l| l["for"] }).to contain_exactly("entities-q", "entities-tags", "entities-sort")
      expect(doc.at_css("input#entities-tags")["aria-describedby"]).to eq("entities-tags-hint")
      expect(doc.css("#entities-tags-hint").size).to eq(1)
    end

    it "marks only the active entity-type tab, as a link (not role=tab)" do
      get entities_path(type: "route")

      expect(nav_current("Entity types")).to eq([ [ "Routes", "page" ] ])
      expect(page.css("nav[aria-label='Entity types'] [role]")).to be_empty
    end

    it "is a real table to assistive technology: rows, column headers and cells, one link per row" do
      create(:kong_entity, kong_connection: connection, name: "payments-api", tags: [ "payment" ])
      create(:kong_entity, kong_connection: connection, name: "orders-api")

      get entities_path(type: "service")
      table = page.at_css("[role='table']")

      expect(table["aria-label"]).to eq("Services")
      headers = table.css("[role='columnheader']").map { |h| h.text.strip }
      expect(headers).to eq(%w[Name Tags Status Updated])
      expect(table.css("[role='rowgroup']").size).to eq(2)
      rows = table.css("#entities-list [role='row']")
      expect(rows.size).to eq(2)
      rows.each do |row|
        expect(row.css("> [role='cell']").size).to eq(headers.size)
        expect(row.css("a").size).to eq(1)
        expect(row["href"]).to be_nil
      end
      expect(rows.first.at_css("a").text.strip).to be_in(%w[payments-api orders-api])
    end

    it "keeps the whole row the click target by stretching the name link, not by making the row a link" do
      css = File.read(Rails.root.join("app/assets/tailwind/application.css"))

      expect(css).to match(/\.entity-link::after\s*\{[^}]*position:\s*absolute;[^}]*inset:\s*0;/m)
      expect(css).to match(/\.entity-table \.entity-row\s*\{[^}]*position:\s*relative;/m)
    end

    it "gives the topbar controls a 36px target, 44px for a coarse pointer" do
      css = File.read(Rails.root.join("app/assets/tailwind/application.css"))
      base = css[/^\.topbar-action\s*\{[^}]*\}/m]
      coarse = css[/@media \(pointer: coarse\)\s*\{\s*\.topbar-action\s*\{[^}]*\}/m]

      expect(base[/min-height:\s*([\d.]+)rem/, 1].to_f * 16).to be >= 36
      expect(coarse[/min-height:\s*([\d.]+)rem/, 1].to_f * 16).to be >= 44
      expect(base[/font-size:\s*([\d.]+)rem/, 1].to_f * 16).to be >= 14
    end

    it "puts the shared target class on Switch, Sign out and every primary nav link" do
      get entities_path

      actions = page.css("header .topbar-action").map { |node| node.text.strip }
      expect(actions).to include("Switch", "Sign out", "Connections", "Entities", "Audit", "Tokens", "Health")
    end

    it "folds CA certificates under the Certificates tab, leaving six tabs" do
      get entities_path(type: "ca_certificate")

      expect(page.css("nav[aria-label='Entity types'] a").size).to eq(6)
      expect(nav_current("Entity types")).to eq([ [ "Certificates", "page" ] ])
      expect(page.css("a").map { |a| a.text.strip }).to include("Certificates", "New CA certificate")
    end

    it "keeps one search field and one button in view, with tags and sort behind a disclosure" do
      get entities_path(type: "service")

      form = page.at_css("form[action='#{entities_path}']")
      expect(form.css("details input#entities-tags, details select#entities-sort").size).to eq(2)
      expect(form.css("details").first["open"]).to be_nil
      expect(form.css("input#entities-q").size).to eq(1)
      expect(page.css(".btn-primary").size).to be <= 1
      expect(page.css("form[action='#{sync_entities_path}'] button, form[action^='#{sync_entities_path}'] button").map { |b| b["class"].split }.flatten).not_to include("btn")
    end

    it "opens the disclosure and offers Clear when tags or a non-default sort are in use" do
      get entities_path(type: "service", tags: "core", sort: "name")

      details = page.at_css("form[action='#{entities_path}'] details")
      expect(details["open"]).not_to be_nil
      expect(details.at_css("summary").text).to include("2 in use")
      expect(page.css("a").map { |a| a.text.strip }).to include("Clear")

      get entities_path(type: "service")
      expect(page.css("a").map { |a| a.text.strip }).not_to include("Clear")
    end

    it "renders the count as a persistent polite live region" do
      create(:kong_entity, kong_connection: connection, name: "payments-api")

      get entities_path
      count = page.at_css("p#entities-count")

      expect(count["role"]).to eq("status")
      expect(count["aria-atomic"]).to eq("true")
      expect(count.text.strip).to eq("1 service shown")
      expect(page.css("#entities-count").size).to eq(1)
    end

    it "updates the live region in place when more rows load" do
      6.times { |n| create(:kong_entity, kong_connection: connection, name: "svc-#{n}", kong_updated_at: n.days.ago) }

      get entities_path, params: { limit: 3, shown: 3 }, as: :turbo_stream

      expect(response.body).to include('turbo-stream action="update" target="entities-count"')
      stream = Nokogiri::HTML.fragment(response.body).at_css("turbo-stream[target='entities-count'] template")
      expect(stream.text.strip).to start_with("6 services shown")
      expect(stream.css("p")).to be_empty # inner text only: the <p role=status> is never replaced
    end
  end

  describe "entity edit / new forms" do
    before { sign_in }

    it "labels the edit Tags field and names the JSON editor" do
      entity = create(:kong_entity, kong_connection: connection, name: "payments-api")
      stub_request(:get, %r{\Ahttps://kong-admin\.test/services/})
        .to_return(status: 200, body: { id: entity.kong_id, name: "payments-api", tags: [] }.to_json)

      get edit_entity_path(entity)
      doc = page

      expect(doc.at_css("label[for='entity-tags']")).to be_present
      expect(doc.css("input#entity-tags").size).to eq(1)
      expect(doc.at_css("textarea[name='payload_json']")["aria-labelledby"]).to eq("json-editor-heading")
      expect(doc.css("#json-editor-heading").size).to eq(1)
      expect(doc.at_css("[data-json-editor-target='status']")["role"]).to eq("status")
    end

    it "names the new-entity JSON editor and marks the chosen 'Start from' preset" do
      get new_entity_path(type: "upstream", preset: Kong::UpstreamPresets.choices.first.first)
      doc = page

      expect(doc.at_css("textarea[name='payload_json']")["aria-labelledby"]).to eq("json-editor-heading")
      expect(doc.css("#json-editor-heading").size).to eq(1)
      expect(doc.at_css("[data-json-editor-target='status']")["role"]).to eq("status")
      expect(doc.css("nav[aria-label='Start from'] [aria-current]").size).to eq(1)
    end
  end

  describe "certificates expiring" do
    it "marks the active window link" do
      sign_in

      get expiring_certificates_path(days: 90)

      expect(nav_current("Window")).to eq([ [ "90 days", "page" ] ])
    end
  end

  describe "tables" do
    before { sign_in }

    it "scopes every column header on the list pages" do
      create(:audit_event, kong_connection: connection)
      create(:change_plan, kong_connection: connection, apply_mode: "pr")
      create(:kong_entity, kong_connection: connection, entity_type: "certificate", not_after: 5.days.from_now)

      [ audit_events_path, change_plans_path, expiring_certificates_path, health_path ].each do |path|
        get path
        expect(response).to have_http_status(:ok)

        headers = page.css("table th")
        expect(headers).not_to be_empty, "#{path}: no <th> rendered"
        headers.each do |th|
          expect(th["scope"]).to be_in(%w[col row]), "#{path}: <th> #{th.text.strip.inspect} lacks scope"
        end
        page.css("thead th").each do |th|
          expect(th["scope"]).to eq("col"), "#{path}: <th> #{th.text.strip.inspect} lacks scope=col"
        end
      end
    end
  end

  describe "banners" do
    before { sign_in }

    it "gives a danger banner role=alert and a success banner role=status on the review page" do
      expired = create(:change_plan, :expired, kong_connection: connection)
      get change_plan_path(expired)
      expect(page.css("main .notice-banner[role='alert']").map(&:text).join).to include("This plan expired")

      applied = create(:change_plan, kong_connection: connection, status: "applied")
      get change_plan_path(applied)
      expect(page.css("main .notice-banner[role='status']").map(&:text).join).to include("Applied")
    end

    it "gives the connection form's error summary role=alert" do
      post connections_path, params: { kong_connection: { name: "" } }

      expect(page.css(".notice-banner[role='alert'] li")).not_to be_empty
    end
  end

  # R1.10: the header names the project and env, and the switcher lists the
  # project's envs -- the current one marked, the ones with no connection shown
  # but not offered.
  describe "env switcher" do
    let(:project) { create(:project, key: "project-a", name: "Project A") }
    let(:dev) { create(:project_env, project: project, name: "dev", position: 1) }
    let!(:current) { create(:kong_connection, project_env: dev, admin_url: "https://kong-a-dev.test") }
    let!(:uat_connection) { create(:kong_connection, project_env: create(:project_env, project: project, name: "uat", position: 3)) }

    before do
      create(:project_env, project: project, name: "sit", position: 2)
      sign_in_to(current)
      get health_path
    end

    it "names the project and the env in the header" do
      expect(page.at_css("header").text).to include("Project A").and include("dev")
    end

    it "lists the project's envs in order, linking each one with a connection to its login" do
      nav = page.at_css("header nav[aria-label='Environments of Project A']")
      expect(nav).to be_present
      items = nav.css("li").map { |li| li.text.squish }
      expect(items.map { |t| t[/\A\S+/] }).to eq(%w[dev sit uat])
      expect(nav.at_css("a[aria-current='page']")["href"]).to eq(login_connection_path(current))
      expect(nav.css("a").map { |a| a["href"] }).to include(login_connection_path(uat_connection))
    end

    it "shows an env with no connection without offering it" do
      nav = page.at_css("header nav[aria-label='Environments of Project A']")
      sit = nav.css("li").find { |li| li.text.include?("sit") }
      expect(sit.at_css("a")).to be_nil
      expect(sit.at_css("[aria-disabled='true']")).to be_present
    end
  end

  # R1.15: two edit links on one row, told apart by name, not by position.
  describe "a connected env's edit links" do
    it "names each link after what it edits and which env" do
      env = create(:project_env, name: "nonprod", rank: 0, source: "local",
        project: create(:project, key: "pay", name: "Pay", source: "local"))
      connection = create(:kong_connection, project_env: env)
      get connections_path
      doc = Nokogiri::HTML(response.body)

      names = doc.css("a[href='#{edit_project_env_path(env)}'], a[href='#{edit_connection_path(connection)}']")
        .map { |a| a["aria-label"] || a.text.squish }
      expect(names).to contain_exactly("Edit environment pay/nonprod", "Edit connection pay/nonprod")
    end
  end
end
