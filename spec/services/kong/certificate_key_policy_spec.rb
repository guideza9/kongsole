require "rails_helper"

RSpec.describe Kong::CertificateKeyPolicy do
  let(:pem_key) { "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0B\n-----END PRIVATE KEY-----\n" }

  describe ".applies_to?" do
    it "is true for a certificate and nothing else" do
      expect(described_class.applies_to?("certificate")).to be(true)
      %w[ca_certificate sni keyauth_credential service].each do |type|
        expect(described_class.applies_to?(type)).to be(false)
      end
    end
  end

  describe "references" do
    it "recognises a vault env reference" do
      expect(described_class.vault_reference?("{vault://env/cert-payments-key}")).to be(true)
    end

    it "rejects lookalikes: other vaults, uppercase names, trailing text, no name" do
      [ "{vault://hcv/secret/key}", "{vault://env/Cert-Key}", "{vault://env/x} ", "{vault://env/}", "vault://env/x", pem_key, nil, 5 ].each do |bad|
        expect(described_class.vault_reference?(bad)).to be(false), "expected #{bad.inspect} not to be a reference"
      end
    end

    it "recognises a decK env placeholder only for DECK_ names" do
      expect(described_class.deck_reference?('${{ env "DECK_CERT_PAYMENTS_KEY" }}')).to be(true)
      expect(described_class.deck_reference?('${{ env "HOME" }}')).to be(false)
    end

    it "treats either form as a reference" do
      expect(described_class.reference?("{vault://env/a}")).to be(true)
      expect(described_class.reference?('${{ env "DECK_A" }}')).to be(true)
      expect(described_class.reference?("plain")).to be(false)
    end
  end

  describe ".env_var_name" do
    it "uppercases a vault name and turns dashes into underscores (verified against Kong 3.7.1)" do
      expect(described_class.env_var_name("{vault://env/cert-payments-key}")).to eq("CERT_PAYMENTS_KEY")
    end

    it "returns the DECK_ name of a decK placeholder as-is" do
      expect(described_class.env_var_name('${{ env "DECK_CERT_A" }}')).to eq("DECK_CERT_A")
    end

    it "is nil for anything that is not a reference" do
      expect(described_class.env_var_name(pem_key)).to be_nil
    end
  end

  describe ".check!" do
    def check(attrs, apply_mode: "direct", operation: nil, entity_type: "certificate")
      described_class.check!(attrs, entity_type: entity_type, apply_mode: apply_mode, operation: operation)
    end

    it "does not apply the key/key_alt rules to other types" do
      expect { check({ "key" => pem_key }, entity_type: "keyauth_credential") }.not_to raise_error
      expect { check({ "key" => "not-a-reference" }, entity_type: "ca_certificate") }.not_to raise_error
    end

    it "accepts a vault reference in key and key_alt in both apply modes" do
      %w[direct pr].each do |mode|
        expect { check({ "key" => "{vault://env/a}", "key_alt" => "{vault://env/b}" }, apply_mode: mode) }.not_to raise_error
      end
    end

    it "accepts a decK placeholder in PR mode" do
      expect { check({ "key" => '${{ env "DECK_A" }}' }, apply_mode: "pr") }.not_to raise_error
    end

    it "rejects a decK placeholder in direct mode -- nothing would inject it" do
      expect { check({ "key" => '${{ env "DECK_A" }}' }, apply_mode: "direct") }
        .to raise_error(described_class::Rejected, /direct/)
    end

    it "rejects a PEM loudly, naming the field and the fix, and never echoing the key" do
      expect { check({ "key" => pem_key }) }.to raise_error(described_class::Rejected) { |e|
        expect(e).to be_a(Kong::ChangePlanner::InvalidChange)
        expect(e.message).to include("key")
        expect(e.message).to include("{vault://env/")
        expect(e.message).not_to include("MIIEvQIBADANBgkqhkiG9w0B")
        expect(e.message).not_to include("BEGIN PRIVATE KEY")
      }
    end

    it "rejects key_alt the same way" do
      expect { check({ "key_alt" => "not-a-reference" }) }.to raise_error(described_class::Rejected, /key_alt/)
    end

    it "lets nil through (clearing key_alt) and skips the inherited redaction marker" do
      expect { check({ "key_alt" => nil }) }.not_to raise_error
      expect { check({ "key" => Kong::Redactor::MARK }) }.not_to raise_error
    end

    it "requires a key on create, but not on update" do
      expect { check({ "snis" => [ "a.example" ] }, operation: "create") }.to raise_error(described_class::Rejected, /needs a key/)
      expect { check({ "tags" => [ "x" ] }, operation: "update") }.not_to raise_error
    end

    describe "a private key nested anywhere in the payload" do
      let(:secret_body) { "MIIEvQIBADANBgkqhkiG9w0B" }

      def expect_rejected(attrs, path, **opts)
        expect { check(attrs, **opts) }.to raise_error(described_class::Rejected) { |e|
          expect(e.message).to include(path)
          expect(e.message).not_to include(secret_body)
          expect(e.message).not_to include("PRIVATE KEY")
        }
      end

      it "rejects a PEM nested under another key, naming the path" do
        expect_rejected({ "foo" => { "key" => pem_key } }, "foo.key")
      end

      it "rejects a PEM inside an array, naming the index" do
        expect_rejected({ "snis" => [ "a.example", pem_key ] }, "snis[1]")
        expect_rejected({ "extra" => [ { "deep" => [ pem_key ] } ] }, "extra[0].deep[0]")
      end

      it "rejects a PEM in a top-level field other than key and key_alt" do
        expect_rejected({ "cert" => pem_key, "key" => "{vault://env/a}" }, "cert")
      end

      it "also applies to ca_certificate and any operation or apply mode" do
        expect_rejected({ "cert" => pem_key }, "cert", entity_type: "ca_certificate", operation: "create")
        expect_rejected({ "meta" => { "k" => pem_key } }, "meta.k", entity_type: "ca_certificate", apply_mode: "pr")
        expect_rejected({ "meta" => { "k" => pem_key } }, "meta.k", operation: "update", apply_mode: "pr")
      end

      it "also applies to an sni (part of the certificate family), in any apply mode, without echoing the key" do
        %w[direct pr].each do |mode|
          expect_rejected({ "name" => "a.example", "meta" => { "k" => pem_key } }, "meta.k", entity_type: "sni", apply_mode: mode)
          expect_rejected({ "name" => pem_key }, "name", entity_type: "sni", apply_mode: mode, operation: "create")
          expect { check({ "name" => "a.example", "extra" => { pem_key => 1 } }, entity_type: "sni", apply_mode: mode) }
            .to raise_error(described_class::Rejected) { |e|
              expect(e.message).not_to include(secret_body)
              expect(e.message).not_to include("PRIVATE")
            }
        end
      end

      it "still leaves other entity types (plugins, services) alone" do
        expect { check({ "config" => { "k" => pem_key } }, entity_type: "plugin") }.not_to raise_error
        expect { check({ "client_certificate" => pem_key }, entity_type: "service") }.not_to raise_error
      end

      it "recognises algorithm-specific private key headers" do
        rsa = "-----BEGIN RSA PRIVATE KEY-----\n#{secret_body}\n-----END RSA PRIVATE KEY-----"
        expect_rejected({ "x" => rsa }, "x")
      end

      it "catches a key embedded in a longer string" do
        expect_rejected({ "notes" => "see below\n#{pem_key}" }, "notes")
      end

      it "does not reject a public CERTIFICATE block" do
        cert = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----\n"
        expect { check({ "cert" => cert, "key" => "{vault://env/a}", "cert_alt" => cert }, operation: "create") }.not_to raise_error
        expect { check({ "cert" => cert }, entity_type: "ca_certificate") }.not_to raise_error
      end

      describe "a private key used as a Hash key" do
        it "rejects a PEM key with a benign value, for certificate and ca_certificate" do
          %w[certificate ca_certificate].each do |type|
            expect { check({ pem_key => 1 }, entity_type: type) }.to raise_error(described_class::Rejected) { |e|
              expect(e.message).not_to include(secret_body)
              expect(e.message).not_to include("BEGIN")
            }
          end
        end

        it "rejects a nested PEM key holding a PEM value without echoing either" do
          %w[certificate ca_certificate].each do |type|
            expect { check({ pem_key => { pem_key => pem_key } }, entity_type: type) }.to raise_error(described_class::Rejected) { |e|
              expect(e.message).not_to include(secret_body)
              expect(e.message).not_to include("BEGIN")
              expect(e.message).not_to include("PRIVATE")
            }
          end
        end

        it "still names the ordinary segments of the path around a removed key" do
          expect { check({ "foo" => { pem_key => [ "x" ], "ok" => { "bar" => pem_key } } }) }
            .to raise_error(described_class::Rejected, /foo\.\[key removed\]/) { |e| expect(e.message).not_to include(secret_body) }
          expect { check({ "foo" => { "ok" => { pem_key => 1 } }, "n" => 1 }, entity_type: "ca_certificate") }
            .to raise_error(described_class::Rejected, /foo\.ok\.\[key removed\]/)
        end

        it "keeps naming a normal path" do
          expect_rejected({ "foo" => { "key" => pem_key } }, "foo.key")
        end

        it "does not reject a public CERTIFICATE block used as a key" do
          cert = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----\n"
          expect { check({ cert => 1 }, entity_type: "certificate", operation: "update") }.not_to raise_error
          expect { check({ cert => 1 }, entity_type: "ca_certificate") }.not_to raise_error
        end
      end

      it "does not reject ordinary strings, numbers, nils and empty containers" do
        attrs = { "tags" => [ "core", "private key rotation" ], "snis" => [], "meta" => { "n" => 1, "z" => nil, "d" => {} } }
        expect { check(attrs, operation: "update") }.not_to raise_error
      end
    end
  end

  describe ".env_vars_for" do
    def plan(operation:, after:, diff: {})
      build(:change_plan, entity_type: "certificate", operation: operation, after: after, diff: diff)
    end

    it "lists the variables a create sets" do
      p = plan(operation: "create", after: { "key" => "{vault://env/cert-a-key}", "key_alt" => "{vault://env/cert-b-key}" })
      expect(described_class.env_vars_for(p)).to eq(%w[CERT_A_KEY CERT_B_KEY])
    end

    it "lists only the key fields an update actually changes" do
      p = plan(operation: "update", after: { "key" => "{vault://env/cert-a-key}", "tags" => %w[x] },
        diff: { "tags" => { "from" => [], "to" => %w[x] } })
      expect(described_class.env_vars_for(p)).to eq([])

      p = plan(operation: "update", after: { "key" => "{vault://env/cert-new}" },
        diff: { "key" => { "from" => "{vault://env/cert-old}", "to" => "{vault://env/cert-new}" } })
      expect(described_class.env_vars_for(p)).to eq(%w[CERT_NEW])
    end

    it "is empty for a delete, a decK placeholder, and any other entity type" do
      expect(described_class.env_vars_for(plan(operation: "delete", after: {}))).to eq([])
      expect(described_class.env_vars_for(plan(operation: "create", after: { "key" => '${{ env "DECK_A" }}' }))).to eq([])
      other = build(:change_plan, entity_type: "sni", operation: "create", after: { "key" => "{vault://env/x}" })
      expect(described_class.env_vars_for(other)).to eq([])
    end
  end

  describe ".scrub" do
    it "replaces a private key block so it is never echoed back to the browser" do
      text = %({"key": "#{pem_key.gsub("\n", '\n')}"})
      body = "before\n#{pem_key}after"

      expect(described_class.scrub(body)).to eq("before\n[private key removed]\nafter")
      expect(described_class.scrub(text)).not_to include("MIIEvQIBADANBgkqhkiG9w0B")
    end

    it "removes a truncated block (BEGIN and some base64, no END) through the end of input" do
      body = "before\n-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0B\nabc"

      expect(described_class.scrub(body)).to eq("before\n[private key removed]")
    end

    it "removes a block whose END line is cut off or malformed" do
      [ "-----END PRIVATE KE", "-----END PRIVATE KEY----", "-----END PRIVATE" ].each do |tail|
        scrubbed = described_class.scrub("x\n-----BEGIN RSA PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0B\n#{tail}")
        expect(scrubbed).to eq("x\n[private key removed]"), "tail #{tail.inspect}"
      end
    end

    it "removes a truncated block in the JSON-escaped form (literal backslash-n)" do
      text = '{"key": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0B\nabc'

      scrubbed = described_class.scrub(text)
      expect(scrubbed).to eq('{"key": "[private key removed]')
      expect(scrubbed).not_to include("MIIEvQIBADANBgkqhkiG9w0B")
    end

    it "preserves text after a terminated block and scrubs each block separately" do
      two = "a\n#{pem_key}b\n#{pem_key}c"

      expect(described_class.scrub(two)).to eq("a\n[private key removed]\nb\n[private key removed]\nc")
    end

    it "handles many BEGIN markers without an END in linear time" do
      body = "-----BEGIN PRIVATE KEY-----\n" * 20_000

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(described_class.scrub(body)).to eq("[private key removed]")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    end

    it "leaves a certificate (public) block and ordinary text alone" do
      cert = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"
      expect(described_class.scrub(cert)).to eq(cert)
      expect(described_class.scrub(nil)).to eq("")
    end
  end

  describe ".deck_vars_for (M5c)" do
    def plan(operation:, after:, diff: {}, entity_type: "certificate", apply_mode: "pr")
      ChangePlan.new(entity_type: entity_type, operation: operation, after: after, diff: diff, apply_mode: apply_mode)
    end

    let(:placeholder) { %q(${{ env "DECK_CERT_PAY_KEY" }}) }

    it "names the variable a PR-mode create sets" do
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => placeholder }))).to eq([ "DECK_CERT_PAY_KEY" ])
    end

    it "names it for an update that changes the key, and not for one that leaves it alone" do
      expect(described_class.deck_vars_for(plan(operation: "update", after: { "key" => placeholder }, diff: { "key" => {} }))).to eq([ "DECK_CERT_PAY_KEY" ])
      expect(described_class.deck_vars_for(plan(operation: "update", after: { "key" => placeholder }, diff: { "tags" => {} }))).to eq([])
    end

    it "is empty for a vault reference (that is what env_vars_for is for), a delete, a direct-mode plan and other types" do
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => "{vault://env/cert-pay-key}" }))).to eq([])
      expect(described_class.deck_vars_for(plan(operation: "delete", after: {}))).to eq([])
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => placeholder }, apply_mode: "direct"))).to eq([])
      expect(described_class.deck_vars_for(plan(operation: "create", after: { "key" => placeholder }, entity_type: "service"))).to eq([])
    end
  end
end
