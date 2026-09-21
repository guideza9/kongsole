require "rails_helper"

RSpec.describe Kong::DeckDocument do
  let(:tags) { [ "managed-by-kongctl", "team-payments" ] }
  let(:pem) { "-----BEGIN CERTIFICATE-----\nAAAA\nBBBB\n-----END CERTIFICATE-----\n" }

  # Every managed type once, nested as decK wants, plus a key the tool does not manage.
  def full_document
    doc = described_class.parse(nil, select_tags: tags)
    doc["services"] = [ {
      "url" => "http://payments:8080", "name" => "payments-api", "tags" => [ "payment" ], "enabled" => true,
      "routes" => [ { "paths" => [ "/pay" ], "name" => "pay-route", "strip_path" => true,
                      "plugins" => [ { "name" => "rate-limiting", "config" => { "policy" => "local", "minute" => 60 } } ] } ],
      "plugins" => [ { "name" => "correlation-id" } ]
    } ]
    doc["upstreams"] = [ { "name" => "orders-up", "targets" => [ { "weight" => 100, "target" => "10.0.0.1:80" } ] } ]
    doc["certificates"] = [
      { "cert" => pem, "id" => "11111111-2222-3333-4444-555555555555", "key" => "{vault://env/cert-pay-key}",
        "snis" => [ { "name" => "pay.example.internal" } ], "tags" => [ "payment" ] },
      { "cert" => "-----BEGIN CERTIFICATE-----\nCCCC\n-----END CERTIFICATE-----\n", "id" => "66666666-7777-8888-9999-000000000000",
        "key" => %q(${{ env "DECK_CERT_OTHER_KEY" }}) }
    ]
    doc["consumers"] = [ { "username" => "reporting-bot", "tags" => [] } ]
    doc["vaults"] = [ { "name" => "env", "prefix" => "env" } ]
    doc
  end

  let(:golden) do
    <<~YAML
      _format_version: '3.0'
      _info:
        select_tags:
          - managed-by-kongctl
          - team-payments
      services:
        - name: payments-api
          enabled: true
          plugins:
            - name: correlation-id
          routes:
            - name: pay-route
              paths:
                - "/pay"
              plugins:
                - name: rate-limiting
                  config:
                    minute: 60
                    policy: local
              strip_path: true
          tags:
            - payment
          url: http://payments:8080
      upstreams:
        - name: orders-up
          targets:
            - target: 10.0.0.1:80
              weight: 100
      certificates:
        - id: 11111111-2222-3333-4444-555555555555
          cert: |
            -----BEGIN CERTIFICATE-----
            AAAA
            BBBB
            -----END CERTIFICATE-----
          key: "{vault://env/cert-pay-key}"
          snis:
            - name: pay.example.internal
          tags:
            - payment
        - id: 66666666-7777-8888-9999-000000000000
          cert: |
            -----BEGIN CERTIFICATE-----
            CCCC
            -----END CERTIFICATE-----
          key: '${{ env "DECK_CERT_OTHER_KEY" }}'
      consumers:
        - username: reporting-bot
          tags: []
      vaults:
        - name: env
          prefix: env
    YAML
  end

  describe ".parse" do
    it "builds a skeleton with no collections when there is no YAML yet" do
      expect(described_class.parse(nil, select_tags: [ "managed-by-kongctl" ])).to eq(
        "_format_version" => "3.0",
        "_info" => { "select_tags" => [ "managed-by-kongctl" ] }
      )
    end

    it "always overwrites select_tags from the connection, even if the file disagrees (rule ข -- mandatory)" do
      doc = described_class.parse("_info:\n  select_tags:\n    - stale-tag\n", select_tags: [ "managed-by-kongctl" ])

      expect(doc["_info"]["select_tags"]).to eq([ "managed-by-kongctl" ])
    end

    it "keeps every key it is given, including ones the tool does not manage" do
      doc = described_class.parse("routes:\n  - name: r\nvaults:\n  - name: env\nconsumer_groups:\n  - name: gold\n", select_tags: [])

      expect(doc.keys).to include("routes", "vaults", "consumer_groups")
    end

    it "raises Unparseable, a guardrail Violation, for text that is not YAML" do
      expect { described_class.parse("services: [unclosed\n", select_tags: []) }
        .to raise_error(described_class::Unparseable, /can't be parsed/) { |error| expect(error).to be_a(Kong::ChangeGuardrails::Violation) }
    end
  end

  describe ".serialize" do
    it "writes the exact bytes for every managed type, nested, with unmanaged keys after" do
      expect(described_class.serialize(full_document)).to eq(golden)
    end

    it "is a fixed point: serialize(parse(serialize(doc))) == serialize(doc)" do
      first = described_class.serialize(full_document)

      expect(described_class.serialize(described_class.parse(first, select_tags: tags))).to eq(first)
    end

    it "leaves out an empty managed collection, since decK rejects a bare `services:` (null)" do
      doc = described_class.parse(nil, select_tags: tags)
      doc["services"] = []
      doc["consumers"] = nil

      expect(described_class.serialize(doc)).to eq("_format_version: '3.0'\n_info:\n  select_tags:\n    - managed-by-kongctl\n    - team-payments\n")
    end

    it "writes the decK env placeholder single-quoted -- the one form decK and a YAML parser both accept" do
      out = described_class.serialize(full_document)

      expect(out).to include(%q(key: '${{ env "DECK_CERT_OTHER_KEY" }}'))
      expect(YAML.safe_load(out)["certificates"][1]["key"]).to eq(%q(${{ env "DECK_CERT_OTHER_KEY" }}))
    end

    it "writes a PEM as a literal block that comes back identical" do
      out = described_class.serialize(full_document)

      expect(out).to include("cert: |\n      -----BEGIN CERTIFICATE-----")
      expect(YAML.safe_load(out)["certificates"][0]["cert"]).to eq(pem)
    end

    it "writes an identity key first, then the rest alphabetically" do
      doc = described_class.parse(nil, select_tags: [])
      doc["services"] = [ { "url" => "http://a", "enabled" => true, "name" => "a" } ]

      expect(described_class.serialize(doc)).to include("services:\n  - name: a\n    enabled: true\n    url: http://a\n")
    end

    it "never folds a long string across lines" do
      doc = described_class.parse(nil, select_tags: [])
      long = "/a b/#{'x' * 200}"
      doc["services"] = [ { "name" => "s", "path" => long } ]

      out = described_class.serialize(doc)

      expect(out.lines.grep(/path:/).size).to eq(1)
      expect(YAML.safe_load(out)["services"][0]["path"]).to eq(long)
    end

    it "keeps scalar types, including strings that look like other types" do
      doc = described_class.parse(nil, select_tags: [])
      doc["services"] = [ { "name" => "s", "port" => 8080, "enabled" => true, "retries" => 5, "tags" => [ "a", "true", "10", "yes: no" ] } ]

      back = YAML.safe_load(described_class.serialize(doc))["services"][0]

      expect(back).to include("port" => 8080, "enabled" => true, "retries" => 5, "tags" => [ "a", "true", "10", "yes: no" ])
    end
  end

  describe ".verify_input!" do
    it "passes when there is no file yet" do
      expect(described_class.verify_input!(nil)).to be_nil
      expect(described_class.verify_input!("")).to be_nil
    end

    it "passes the tool's own output" do
      expect(described_class.verify_input!(golden)).to be_nil
    end

    it "tolerates the bare `services:` the tool wrote before M5c (decK itself rejects that line; the re-render drops it)" do
      legacy = "_format_version: '3.0'\n_info:\n  select_tags:\n    - managed-by-kongctl\nservices:\n"

      expect(described_class.verify_input!(legacy)).to be_nil
      expect(described_class.serialize(described_class.parse(legacy, select_tags: [ "managed-by-kongctl" ]))).not_to include("services")
    end

    it "refuses hand-formatted YAML, naming the first line that would change" do
      hand = "_format_version: '3.0'\n_info:\n  select_tags: [team-a]\nservices:\n  - {name: orders, url: 'http://orders:80'}\n"

      expect { described_class.verify_input!(hand) }
        .to raise_error(described_class::Unparseable, /would not survive a re-render unchanged \(first difference at line \d+\)/)
    end

    it "refuses a file with a comment, which a re-render would silently delete" do
      expect { described_class.verify_input!("# owned by team-a\n#{golden}") }.to raise_error(described_class::Unparseable)
    end

    it "refuses YAML anchors and aliases" do
      anchored = "_format_version: '3.0'\n_info:\n  select_tags: []\nservices:\n  - &s\n    name: a\n  - *s\n"

      expect { described_class.verify_input!(anchored) }.to raise_error(described_class::Unparseable)
    end

    it "refuses text that is not YAML at all" do
      expect { described_class.verify_input!("services: [unclosed\n") }.to raise_error(described_class::Unparseable, /can't be parsed/)
    end

    it "regression (spec 1.6): collections the tool does not manage survive an edit instead of being dropped" do
      text = described_class.serialize(described_class.parse(<<~YAML, select_tags: tags))
        _format_version: '3.0'
        _info:
          select_tags:
            - managed-by-kongctl
            - team-payments
        consumer_groups:
          - name: gold-tier
        routes:
          - name: flat-route
        vaults:
          - name: env
            prefix: env
      YAML
      described_class.verify_input!(text)

      doc = described_class.parse(text, select_tags: tags)
      doc["services"] = [ { "name" => "new-service" } ]
      out = described_class.serialize(doc)

      expect(out).to include("consumer_groups:", "gold-tier", "routes:", "flat-route", "vaults:", "new-service")
    end
  end
end
