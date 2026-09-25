require "rails_helper"
require Rails.root.join("spec/support/bare_git_repo")

# R8.8: the changeset pages -- list, show, preview, remove an item, submit,
# record the PR URL, abandon.
RSpec.describe "Changesets", type: :request do
  include SignInHelper
  include BareGitRepo

  let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]) }
  let(:connection) do
    pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[managed-by-kongctl]).tap { _1.update!(admin_url: "https://kong.test") }
  end
  let(:changeset) { create(:changeset, kong_connection: connection, base_git_sha: head_sha(repo)) }

  def add_item(name, position)
    create(:change_plan, changeset: changeset, kong_connection: connection, position: position, apply_mode: "pr",
      status: "pending", operation: "create", entity_type: "service", provisional_kong_id: SecureRandom.uuid,
      target_kong_id: nil, before: {}, diff: { "operation" => "create" },
      after: { "name" => name, "host" => "#{name}.internal", "tags" => %w[managed-by-kongctl] })
  end

  before do
    sign_in_to(connection, access: :ro) # uat -> rank 2
    stub_request(:get, "https://kong.test/").to_return(status: 200, body: { version: "3.7.1" }.to_json) # re-auth probe
    allow(Kong::DeckCli).to receive(:validate).and_return(true)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [], "updating" => [], "deleting" => [] } })
  end

  it "shows the open changeset's items and removes one" do
    keep = add_item("billing", 1)
    drop = add_item("ledger", 2)

    get changeset_path(changeset)
    expect(response.body).to include("billing", "ledger")

    delete changeset_item_path(changeset, drop)
    expect(response).to redirect_to(changeset_path(changeset))
    expect(drop.reload.status).to eq("cancelled")
    expect(changeset.items.reload).to eq([ keep ])
  end

  it "lists the connection's changesets, the open one first" do
    old = create(:changeset, kong_connection: connection, status: "submitted", branch: "kongctl/changeset-1", submitted_at: 1.day.ago)
    changeset
    get changesets_path
    expect(response.body.index(changeset_path(changeset))).to be < response.body.index(changeset_path(old))
  end

  it "previews the YAML diff and the gate without pushing" do
    add_item("billing", 1)
    get preview_changeset_path(changeset)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("+  - name: billing", "Clear")
    expect(Open3.capture3("git", "--git-dir=#{repo}", "branch", "--list", "kongctl/*").first).to be_empty
  end

  it "submits only with the retyped connection name and password at rank >= 2" do
    add_item("billing", 1)
    post submit_changeset_path(changeset), params: { confirm_env_name: "wrong", password: "pw" }
    expect(changeset.reload).to be_open
    post submit_changeset_path(changeset), params: { confirm_env_name: connection.name, password: "pw", acknowledge_drift: "1" }
    expect(response).to redirect_to(changeset_path(changeset))
    expect(changeset.reload.status).to eq("submitted")
  end

  it "says why a submit was refused and keeps the changeset open" do
    add_item("billing", 1)
    connection.project_env.project.update!(delete_threshold: 1)
    allow(Kong::DeckCli).to receive(:diff).and_return({ "changes" => { "creating" => [], "updating" => [],
      "deleting" => [ { "kind" => "service", "name" => "x" }, { "kind" => "service", "name" => "y" } ] } })
    post submit_changeset_path(changeset), params: { confirm_env_name: connection.name, password: "pw" }
    expect(flash[:alert]).to include("over the threshold of 1")
    expect(changeset.reload).to be_open
  end

  it "accepts a pasted PR URL only on the project's git host" do
    changeset.update!(status: "submitted", branch: "kongctl/changeset-1")
    connection.project_env.project.update!(git_web_url: "https://git.example/team/repo/tree/{branch}")
    patch pr_url_changeset_path(changeset), params: { pr_url: "https://evil.example/pr/1" }
    expect(changeset.reload.pr_url).to be_nil
    patch pr_url_changeset_path(changeset), params: { pr_url: "javascript:alert(1)" }
    expect(changeset.reload.pr_url).to be_nil
    patch pr_url_changeset_path(changeset), params: { pr_url: "https://git.example/team/repo/pull/7" }
    expect(changeset.reload.pr_url).to eq("https://git.example/team/repo/pull/7")
  end

  it "abandons an open changeset, cancelling its items" do
    item = add_item("billing", 1)
    post abandon_changeset_path(changeset)
    expect(changeset.reload.status).to eq("abandoned")
    expect(item.reload.status).to eq("cancelled")
  end

  it "shows only the current connection's changesets" do
    other = create(:changeset)
    get changeset_path(other)
    expect(response).to have_http_status(:not_found)
  end

  it "sends the pending-PRs list of a PR-mode connection to its changesets" do
    get change_plans_path
    expect(response).to redirect_to(changesets_path)
  end

  it "shows a plan in a changeset as an item of it, with no Apply" do
    plan = add_item("billing", 1)
    get change_plan_path(plan)
    expect(response.body).to include("In changeset ##{changeset.id}", changeset_path(changeset))
    expect(response.body).not_to include('id="apply-plan-form"')
  end

  it "sends Apply on a plan in a changeset to that changeset" do
    plan = add_item("billing", 1)
    post apply_change_plan_path(plan), params: { confirm_env_name: connection.name, password: "pw" }
    expect(response).to redirect_to(changeset_path(changeset))
    expect(flash[:alert]).to include("changeset")
  end
  it "does not call a git failure that is not a network one a network problem on submit (R8.10)" do
    add_item("billing", 1)
    allow_any_instance_of(Kong::GitClient).to receive(:push!).and_raise(Kong::GitClient::Error, "git push failed: remote rejected")
    post submit_changeset_path(changeset), params: { confirm_env_name: connection.name, password: "pw", acknowledge_drift: "1" }
    expect(flash[:alert]).to include("remote rejected")
    expect(flash[:error_explanation]).to be_nil
  end
  # Final review #4: the review asks for each delete's own name at rank >= 2.
  it "asks for each delete's name on the review, and passes it to the submit" do
    dir = @bare_git_tmp.join("seed-#{SecureRandom.hex(4)}")
    Open3.capture3("git", "clone", repo.to_s, dir.to_s)
    File.write(dir.join("uat", "kong.yaml"), Kong::DeckDocument.serialize(Kong::DeckDocument.parse("services:\n  - name: orders\n", select_tags: %w[managed-by-kongctl])))
    Open3.capture3("git", "add", "-A", chdir: dir.to_s)
    Open3.capture3("git", "-c", "user.name=s", "-c", "user.email=s@example.com", "commit", "-m", "s", chdir: dir.to_s)
    Open3.capture3("git", "push", "origin", "main", chdir: dir.to_s)
    changeset.update!(base_git_sha: head_sha(repo))
    kong_id = SecureRandom.uuid
    item = create(:change_plan, :delete, changeset: changeset, kong_connection: connection, apply_mode: "pr", position: 1,
      entity_type: "service", target_kong_id: kong_id, before: { "id" => kong_id, "name" => "orders", "tags" => [] })
    stub_request(:get, "https://kong.test/services/#{kong_id}")
      .to_return(status: 200, body: { id: kong_id, name: "orders", updated_at: 1_700_000_000 }.to_json)

    get preview_changeset_path(changeset)
    field = Nokogiri::HTML(response.body).at_css("form#submit-changeset-form input[name='confirm_delete[#{item.id}]']")
    expect(field).to be_present

    post submit_changeset_path(changeset), params: { confirm_env_name: connection.name, password: "pw", confirm_delete: { item.id.to_s => "orders" } }
    expect(changeset.reload.status).to eq("submitted")
  end
end
