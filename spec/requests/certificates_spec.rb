require "rails_helper"

RSpec.describe "Certificates expiring (web)", type: :request do
  let(:connection) { create(:kong_connection, admin_url: "https://kong-admin.test", credential_mode: "session") }

  def sign_in
    stub_request(:get, "https://kong-admin.test/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "https://kong-admin.test#{Kong::AccessProbe::PROBE_PATH}").to_return(status: 404, body: { message: "Not found" }.to_json)
    stub_request(:get, "https://kong-admin.test/consumers/alice").to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "https://kong-admin.test/routes").to_return(status: 200, body: { data: [], offset: nil }.to_json)
    post login_connection_path(connection), params: { username: "alice", password: "pw" }
  end

  def cert(name, not_after, type: "certificate", conn: connection, **attrs)
    create(:kong_entity, kong_connection: conn, entity_type: type, name: name, not_after: not_after, **attrs)
  end

  it "redirects to the root path when nobody is signed in" do
    get expiring_certificates_path

    expect(response).to redirect_to(root_path)
  end

  it "lists certificates and CA certificates expiring inside the window, soonest first, expired included" do
    sign_in
    cert("later.example", 20.days.from_now)
    cert("gone.example", 3.days.ago)
    cert("root-ca", 5.days.from_now, type: "ca_certificate")
    cert("far.example", 200.days.from_now)

    get expiring_certificates_path

    body = response.body
    expect(body).to include("gone.example").and include("root-ca").and include("later.example")
    expect(body).not_to include("far.example")
    expect(body.index("gone.example")).to be < body.index("root-ca")
    expect(body.index("root-ca")).to be < body.index("later.example")
    expect(body).to include("Expired").and include("Critical").and include("Warning")
  end

  it "is scoped to the current connection: another connection's certificates never appear" do
    sign_in
    other = create(:kong_connection, name: "prod-other")
    cert("mine.example", 5.days.from_now)
    cert("theirs.example", 5.days.from_now, conn: other)

    get expiring_certificates_path

    expect(response.body).to include("mine.example")
    expect(response.body).not_to include("theirs.example")
  end

  it "leaves out soft-deleted rows, non-certificates, and rows with no expiry" do
    sign_in
    cert("deleted.example", 5.days.from_now, deleted_at: 1.hour.ago)
    create(:kong_entity, kong_connection: connection, entity_type: "service", name: "svc-no-expiry")
    cert("unparsed.example", nil)

    get expiring_certificates_path

    expect(response.body).not_to include("deleted.example")
    expect(response.body).not_to include("svc-no-expiry")
    expect(response.body).not_to include("unparsed.example")
  end

  it "narrows to the requested window, and ignores a nonsense one" do
    sign_in
    cert("soon.example", 5.days.from_now)
    cert("month.example", 20.days.from_now)

    get expiring_certificates_path(days: 7)
    expect(response.body).to include("soon.example")
    expect(response.body).not_to include("month.example")

    get expiring_certificates_path(days: "banana")
    expect(response.body).to include("month.example") # back to 30
    get expiring_certificates_path(days: -5)
    expect(response.body).to include("month.example")
  end

  it "says so when nothing is expiring, and how fresh the data is" do
    sign_in

    get expiring_certificates_path

    expect(response.body).to include("Nothing expires within 30 days")
    expect(response.body).to include("never synced")
  end

  it "links each row to its entity page" do
    sign_in
    certificate = cert("linked.example", 5.days.from_now)

    get expiring_certificates_path

    expect(response.body).to include(entity_path(certificate))
  end

  it "is reachable from the certificates tab" do
    sign_in

    get entities_path(type: "certificate")

    expect(response.body).to include(expiring_certificates_path)
  end
end
