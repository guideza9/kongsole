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
end
