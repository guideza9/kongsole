require "rails_helper"

RSpec.describe "API::V1::Certificates", type: :request do
  def auth(raw) = { "Authorization" => "Bearer #{raw}" }

  def token_for(*connections)
    _pat, raw = PersonalAccessToken.issue!(operator: "alice", issued_by_username: "alice", connection_ids: connections.map(&:id))
    raw
  end

  let(:dev) { create(:kong_connection, name: "dev", credential_mode: "stored", auth_secret: "s3cr3t") }
  let(:sit) { create(:kong_connection, name: "sit", env: "sit", credential_mode: "stored", auth_secret: "s3cr3t") }
  let(:prod) { create(:kong_connection, name: "prod", env: "prod", credential_mode: "stored", auth_secret: "s3cr3t") }

  def cert(connection, name, not_after, type: "certificate", **attrs)
    create(:kong_entity, kong_connection: connection, entity_type: type, name: name, not_after: not_after,
      data: { "snis" => [ name ], "_metadata" => { "fingerprint_sha256" => "a" * 64 } }, **attrs)
  end

  it "requires a token" do
    get expiring_api_v1_certificates_path

    expect(response).to have_http_status(:unauthorized)
  end

  it "covers every connection the token is bound to, soonest first, and none it is not" do
    cert(dev, "dev.example", 20.days.from_now)
    cert(sit, "sit.example", 3.days.from_now)
    cert(prod, "prod.example", 1.day.from_now) # not bound to the token

    get expiring_api_v1_certificates_path, headers: auth(token_for(dev, sit))

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["data"].map { |c| c["name"] }).to eq(%w[sit.example dev.example])
    expect(json["data"].map { |c| c["connection"] }).to eq(%w[sit/sit dev/dev])
    expect(json["meta"]).to include("days" => 30, "connections" => %w[dev/dev sit/sit])
  end

  it "reports type, snis, expiry, days left and status, and never a key or a PEM" do
    cert(dev, "pay.example", 5.days.from_now)
    cert(dev, "root-ca", 2.days.ago, type: "ca_certificate")

    get expiring_api_v1_certificates_path, headers: auth(token_for(dev))

    rows = JSON.parse(response.body)["data"].index_by { |r| r["name"] }
    expect(rows["pay.example"]).to include("type" => "certificate", "snis" => [ "pay.example" ], "status" => "critical")
    expect(rows["pay.example"]["days_left"]).to eq(4) # created an instant ago, so a hair under 5 days, floored
    expect(Time.iso8601(rows["pay.example"]["not_after"])).to be_within(1.minute).of(5.days.from_now)
    expect(rows["root-ca"]).to include("type" => "ca_certificate", "status" => "expired")
    expect(rows["root-ca"]["days_left"]).to be_negative
    expect(response.body).not_to include("PRIVATE KEY")
    expect(rows["pay.example"]["kong_id"]).to be_present
    expect(rows["pay.example"].keys).not_to include("key", "cert", "data")
  end

  it "narrows to one named connection, and refuses one the token isn't bound to" do
    cert(dev, "dev.example", 5.days.from_now)
    cert(sit, "sit.example", 5.days.from_now)
    token = token_for(dev, sit)

    get expiring_api_v1_certificates_path(connection: "sit/sit"), headers: auth(token)
    expect(JSON.parse(response.body)["data"].map { |c| c["name"] }).to eq([ "sit.example" ])

    get expiring_api_v1_certificates_path(connection: "prod/prod"), headers: auth(token)
    expect(response).to have_http_status(:unauthorized)
  end

  it "honours the days window and falls back to 30 for nonsense" do
    cert(dev, "soon.example", 5.days.from_now)
    cert(dev, "month.example", 20.days.from_now)
    token = token_for(dev)

    get expiring_api_v1_certificates_path(days: 7), headers: auth(token)
    expect(JSON.parse(response.body)["data"].map { |c| c["name"] }).to eq([ "soon.example" ])

    get expiring_api_v1_certificates_path(days: "x"), headers: auth(token)
    expect(JSON.parse(response.body)["meta"]["days"]).to eq(30)
  end

  it "falls back to 30 for out-of-range days" do
    token = token_for(dev)

    [ 0, -5, 3651 ].each do |days|
      get expiring_api_v1_certificates_path(days: days), headers: auth(token)

      expect(JSON.parse(response.body)["meta"]["days"]).to eq(30), "days=#{days}"
    end
  end

  it "survives array and hash days params -- a 200 with the default window, never a 500" do
    cert(dev, "soon.example", 5.days.from_now)
    token = token_for(dev)

    [ "days[]=1", "days[a]=1", "days[]=1&days[]=2" ].each do |query|
      get "#{expiring_api_v1_certificates_path}?#{query}", headers: auth(token)

      expect(response).to have_http_status(:ok), query
      expect(JSON.parse(response.body)["meta"]["days"]).to eq(30), query
    end
  end

  it "answers 401 -- never 500 -- for an array or hash connection param" do
    token = token_for(dev)

    [ "connection[]=dev", "connection[a]=dev", "connection[]=dev&connection[]=sit" ].each do |query|
      get "#{expiring_api_v1_certificates_path}?#{query}", headers: auth(token)

      expect(response).to have_http_status(:unauthorized), query
    end
  end

  it "treats an empty connection param as absent" do
    cert(dev, "dev.example", 5.days.from_now)

    get expiring_api_v1_certificates_path(connection: ""), headers: auth(token_for(dev))

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["data"].size).to eq(1)
  end

  it "rejects a wrong bearer token" do
    get expiring_api_v1_certificates_path, headers: auth("not-a-real-token")

    expect(response).to have_http_status(:unauthorized)
  end

  it "excludes soft-deleted certificates, ones with no not_after, and non-certificate entity types" do
    cert(dev, "live.example", 5.days.from_now)
    cert(dev, "deleted.example", 5.days.from_now, deleted_at: 1.hour.ago)
    cert(dev, "undated.example", nil)
    cert(dev, "an-upstream", 5.days.from_now, type: "upstream")

    get expiring_api_v1_certificates_path, headers: auth(token_for(dev))

    expect(JSON.parse(response.body)["data"].map { |c| c["name"] }).to eq([ "live.example" ])
  end
end
