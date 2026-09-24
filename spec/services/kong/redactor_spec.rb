require "rails_helper"

RSpec.describe Kong::Redactor do
  it "redacts a certificate's private key" do
    result = described_class.call("certificate", { "id" => "c1", "cert" => "-----BEGIN CERT", "key" => "-----BEGIN KEY" })
    expect(result[:data]["key"]).to eq("[REDACTED]")
    expect(result[:data]["cert"]).to eq("-----BEGIN CERT")
  end

  it "redacts a basic-auth credential's password" do
    result = described_class.call("basicauth_credential", { "username" => "alice", "password" => "$2y$hash" })
    expect(result[:data]["password"]).to eq("[REDACTED]")
    expect(result[:data]["username"]).to eq("alice")
  end

  it "redacts a key-auth credential's key" do
    result = described_class.call("keyauth_credential", { "key" => "abc123" })
    expect(result[:data]["key"]).to eq("[REDACTED]")
  end

  it "leaves unrelated fields on unrelated entities untouched" do
    result = described_class.call("service", { "name" => "payments", "host" => "payments.internal" })
    expect(result[:data]).to eq({ "name" => "payments", "host" => "payments.internal" })
  end

  it "redacts nested secrets inside arrays/hashes" do
    result = described_class.call("service", {
      "name" => "payments",
      "credentials" => [ { "password" => "hunter2" } ]
    })
    expect(result[:data]["credentials"].first["password"]).to eq("[REDACTED]")
  end

  it "computes the digest from the redacted payload, not the raw one" do
    raw = { "key" => "super-secret" }
    redacted = described_class.call("certificate", raw)
    clean = described_class.call("certificate", { "key" => "[REDACTED]" })
    expect(redacted[:digest]).to eq(clean[:digest])
  end

  it "never returns the plaintext secret anywhere in the result, even nested" do
    result = described_class.call("certificate", { "key" => "top-secret-value" })
    expect(result.to_s).not_to include("top-secret-value")
  end

  describe ".prune_marked" do
    it "drops keys still holding the redaction marker, at any depth" do
      pruned = described_class.prune_marked({
        "name" => "payments",
        "key" => "[REDACTED]",
        "nested" => { "password" => "[REDACTED]", "port" => 8080 },
        "list" => [ { "secret" => "[REDACTED]", "keep" => true } ]
      })

      expect(pruned).to eq({
        "name" => "payments",
        "nested" => { "port" => 8080 },
        "list" => [ { "keep" => true } ]
      })
    end

    it "keeps a real value a caller supplied for a secret field" do
      pruned = described_class.prune_marked({ "key" => "a-genuinely-new-key" })

      expect(pruned).to eq({ "key" => "a-genuinely-new-key" })
    end
  end

  describe ".prune_sensitive" do
    it "drops secret-named fields whatever their value, so a retyped secret goes too" do
      pruned = described_class.prune_sensitive("keyauth_credential", {
        "key" => "someone-typed-a-real-key",
        "consumer" => { "id" => "abc" },
        "tags" => [ "x" ]
      })

      expect(pruned).to eq({ "consumer" => { "id" => "abc" }, "tags" => [ "x" ] })
    end

    it "leaves a same-named field alone on an entity_type where it isn't a secret" do
      pruned = described_class.prune_sensitive("service", { "name" => "payments", "port" => 8080 })

      expect(pruned).to eq({ "name" => "payments", "port" => 8080 })
    end
  end

  describe "certificate key references (M5b)" do
    it "lets a vault reference through, since it is a pointer and not a secret" do
      result = described_class.call("certificate", { "key" => "{vault://env/cert-a-key}", "cert" => "PEM" })

      expect(result[:data]["key"]).to eq("{vault://env/cert-a-key}")
    end

    it "lets a decK placeholder through too" do
      result = described_class.call("certificate", { "key" => '${{ env "DECK_A" }}' })

      expect(result[:data]["key"]).to eq('${{ env "DECK_A" }}')
    end

    it "still redacts a plaintext key, in key and in key_alt" do
      pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
      result = described_class.call("certificate", { "key" => pem, "key_alt" => pem })

      expect(result[:data]).to eq({ "key" => "[REDACTED]", "key_alt" => "[REDACTED]" })
    end

    it "passes a reference in key_alt through as well" do
      result = described_class.call("certificate", { "key_alt" => "{vault://env/cert-b-key}" })

      expect(result[:data]["key_alt"]).to eq("{vault://env/cert-b-key}")
    end

    it "does not extend the passthrough to any other entity type" do
      result = described_class.call("keyauth_credential", { "key" => "{vault://env/looks-like-a-ref}" })

      expect(result[:data]["key"]).to eq("[REDACTED]")
    end

    it "keeps certificate keys out of prune_sensitive so the planner's policy can reject a PEM loudly" do
      data = { "key" => "-----BEGIN PRIVATE KEY-----\nA\n-----END PRIVATE KEY-----", "key_alt" => "{vault://env/x}", "tags" => [ "t" ] }

      expect(described_class.prune_sensitive("certificate", data)).to eq(data)
    end

    it "still prunes a credential secret from a form exactly as before" do
      expect(described_class.prune_sensitive("keyauth_credential", { "key" => "s", "tags" => [] })).to eq({ "tags" => [] })
    end

    it "digests the redacted form, so a reference change changes the digest" do
      a = described_class.call("certificate", { "key" => "{vault://env/a}" })
      b = described_class.call("certificate", { "key" => "{vault://env/b}" })

      expect(a[:digest]).not_to eq(b[:digest])
    end
  end

  describe "plugins" do
    let(:plugin) do
      { "name" => "aws-lambda", "config" => {
        "aws_key" => "AKIAREALKEY", "aws_region" => "ap-southeast-1",
        "redis" => { "password" => "pw", "host" => "r" },
        "vaulted" => "{vault://env/aws-secret}"
      } }
    end

    it "redacts the schema's secret paths at any depth" do
      data = described_class.call("plugin", plugin, secret_paths: [ %w[config aws_key], %w[config redis password] ])[:data]
      expect(data.dig("config", "aws_key")).to eq(described_class::MARK)
      expect(data.dig("config", "redis", "password")).to eq(described_class::MARK)
      expect(data.dig("config", "aws_region")).to eq("ap-southeast-1")
    end

    it "keeps a vault reference visible on a referenceable field -- it names a variable, it is not a secret" do
      data = described_class.call("plugin", plugin, secret_paths: [ %w[config vaulted] ])[:data]
      expect(data.dig("config", "vaulted")).to eq("{vault://env/aws-secret}")
    end

    it "keeps a vault reference on a secret-named field too, with or without a schema" do
      input = { "name" => "rate-limiting", "config" => { "redis" => { "password" => "{vault://env/redis-pw}" },
                                                         "secret" => "{vault://env/session}" } }
      [ [ %w[config redis password], %w[config secret] ], nil ].each do |paths|
        data = described_class.call("plugin", input, secret_paths: paths)[:data]
        expect(data.dig("config", "redis", "password")).to eq("{vault://env/redis-pw}")
        expect(data.dig("config", "secret")).to eq("{vault://env/session}")
      end
    end

    it "fails closed without a schema: secret-looking names and any headers map are redacted" do
      input = { "name" => "http-log", "config" => {
        "http_endpoint" => "https://x", "headers" => { "Authorization" => "Basic abc" }, "api_token" => "t" } }
      data = described_class.call("plugin", input, secret_paths: nil)[:data]
      expect(data.dig("config", "headers")).to eq(described_class::MARK)
      expect(data.dig("config", "api_token")).to eq(described_class::MARK)
      expect(data.dig("config", "http_endpoint")).to eq("https://x")
    end
  end
end
