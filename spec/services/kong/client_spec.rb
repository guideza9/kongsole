require "rails_helper"

RSpec.describe Kong::Client do
  let(:connection) { build(:kong_connection, admin_url: "http://kong-admin.test", auth_username: "kongctl") }
  let(:client) { described_class.new(connection: connection, secret: "s3cr3t-password") }

  describe "error mapping (docs/DESIGN.md section 1.4)" do
    it "raises Unauthorized on a basic-auth plugin rejection" do
      stub_request(:get, "http://kong-admin.test/").to_return(
        status: 401,
        headers: { "WWW-Authenticate" => 'Basic realm="kong"' },
        body: { message: "Unauthorized" }.to_json
      )
      expect { client.get("/") }.to raise_error(Kong::Client::Unauthorized)
    end

    it "raises Forbidden on an ACL plugin rejection" do
      stub_request(:get, "http://kong-admin.test/services").to_return(
        status: 403,
        body: { message: "You cannot consume this service" }.to_json
      )
      expect { client.get("/services") }.to raise_error(Kong::Client::Forbidden)
    end

    it "raises RouteNotMatched when Kong's router rejects the request (e.g. read-only credential on a write)" do
      stub_request(:patch, "http://kong-admin.test/services/x").to_return(
        status: 404,
        body: { message: "no Route matched with those values" }.to_json
      )
      expect { client.patch("/services/x") }.to raise_error(Kong::Client::RouteNotMatched)
    end

    it "raises EntityNotFound when the Admin API itself reports the entity is missing" do
      stub_request(:get, "http://kong-admin.test/services/nope").to_return(
        status: 404,
        body: { message: "Not found" }.to_json
      )
      expect { client.get("/services/nope") }.to raise_error(Kong::Client::EntityNotFound)
    end

    it "raises RateLimited on a rate-limiting plugin rejection" do
      stub_request(:get, "http://kong-admin.test/services").to_return(
        status: 429,
        body: { message: "API rate limit exceeded" }.to_json
      )
      expect { client.get("/services") }.to raise_error(Kong::Client::RateLimited)
    end

    it "raises UpstreamUnavailable on a 503 from the loopback service" do
      stub_request(:get, "http://kong-admin.test/").to_return(status: 503, body: "")
      expect { client.get("/") }.to raise_error(Kong::Client::UpstreamUnavailable)
    end

    it "raises UpstreamUnavailable on a connection failure" do
      stub_request(:get, "http://kong-admin.test/").to_raise(Faraday::ConnectionFailed)
      expect { client.get("/") }.to raise_error(Kong::Client::UpstreamUnavailable)
    end
  end

  describe "successful requests" do
    it "returns the response on 2xx" do
      stub_request(:get, "http://kong-admin.test/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
      response = client.get("/")
      expect(response.status).to eq(200)
    end

    it "sends the credential as HTTP Basic auth" do
      stub_request(:get, "http://kong-admin.test/")
        .with(basic_auth: %w[kongctl s3cr3t-password])
        .to_return(status: 200, body: "{}")
      client.get("/")
    end
  end

  describe "log safety" do
    it "never writes the raw Authorization header to the Rails log" do
      stub_request(:get, "http://kong-admin.test/").to_return(status: 200, body: "{}")

      logged = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(logged)

      begin
        Rails.logger.info("about to call Kong for connection #{connection.name}")
        client.get("/")
        Rails.logger.info("Kong call finished")
      ensure
        Rails.logger = original_logger
      end

      expect(logged.string).not_to include("Basic ")
      expect(logged.string).not_to include("s3cr3t-password")
    end
  end
end
