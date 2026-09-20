require "rails_helper"
require Rails.root.join("spec/support/pem_fixtures")

RSpec.describe Kong::CertificateMetadata do
  describe ".parse" do
    it "extracts the fields the read-model and dashboard need" do
      fixture = PemFixtures.self_signed(cn: "pay.example.internal", days: 90, sans: %w[pay.example.internal api.example.internal])

      meta = described_class.parse(fixture[:cert_pem])

      expect(meta["subject"]).to include("CN=pay.example.internal")
      expect(meta["issuer"]).to include("CN=pay.example.internal") # self-signed
      expect(meta["fingerprint_sha256"]).to eq(fixture[:der_sha256])
      expect(meta["fingerprint_sha256"]).to match(/\A\h{64}\z/)
      expect(meta["sans"]).to eq(%w[DNS:pay.example.internal DNS:api.example.internal])
      expect(meta["serial"]).to be_present
      expect(Time.iso8601(meta["not_after"])).to be_within(5.seconds).of(90.days.from_now)
      expect(Time.iso8601(meta["not_before"])).to be < Time.current
      expect(meta).not_to have_key("parse_error")
    end

    it "has no SANs when the certificate carries none" do
      expect(described_class.parse(PemFixtures.self_signed[:cert_pem])["sans"]).to eq([])
    end

    it "parses an already-expired certificate" do
      meta = described_class.parse(PemFixtures.self_signed(days: -10)[:cert_pem])

      expect(Time.iso8601(meta["not_after"])).to be < Time.current
    end

    it "accepts the CRLF line endings Kong returns" do
      pem = PemFixtures.self_signed[:cert_pem].gsub("\n", "\r\n")

      expect(described_class.parse(pem)).to have_key("fingerprint_sha256")
    end

    it "reports a parse_error instead of raising, for garbage, blank and nil" do
      [ "not a certificate", "", nil, "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----" ].each do |bad|
        meta = described_class.parse(bad)
        expect(meta.keys).to eq([ "parse_error" ]), "expected only parse_error for #{bad.inspect}"
        expect(meta["parse_error"]).to be_present
      end
    end

    it "never puts the offending PEM text into the parse_error" do
      meta = described_class.parse("-----BEGIN CERTIFICATE-----\nSECRETISH\n-----END CERTIFICATE-----")

      expect(meta["parse_error"]).not_to include("SECRETISH")
    end

    it "reports a parse_error, not an exception, when a malformed extension raises an OpenSSL error" do
      pem = PemFixtures.self_signed(cn: "pay.example.internal", days: 30, sans: %w[pay.example.internal])[:cert_pem]
      allow_any_instance_of(OpenSSL::X509::Certificate).to receive(:extensions).and_raise(OpenSSL::X509::ExtensionError)

      meta = described_class.parse(pem)

      expect(meta.keys).to eq([ "parse_error" ])
      expect(meta["parse_error"]).to eq("OpenSSL::X509::ExtensionError")
    end
  end

  describe ".not_after_time" do
    it "returns the expiry as a Time" do
      meta = described_class.parse(PemFixtures.self_signed(days: 30)[:cert_pem])

      expect(described_class.not_after_time(meta)).to be_within(5.seconds).of(30.days.from_now)
    end

    it "is nil when there is no not_after (a parse error)" do
      expect(described_class.not_after_time({ "parse_error" => "x" })).to be_nil
      expect(described_class.not_after_time(nil)).to be_nil
    end
  end
end
