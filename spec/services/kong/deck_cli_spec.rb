require "rails_helper"
require Rails.root.join("spec/support/pem_fixtures")

RSpec.describe Kong::DeckCli do
  let(:success) { instance_double(Process::Status, success?: true) }
  let(:failure) { instance_double(Process::Status, success?: false) }
  let(:file) { Rails.root.join("tmp", "deck_cli_spec.yaml") }

  describe "with the process boundary stubbed" do
    around do |example|
      saved = ENV["DECK_BIN"]
      ENV.delete("DECK_BIN")
      example.run
    ensure
      ENV["DECK_BIN"] = saved
    end

    before do
      FileUtils.mkdir_p(file.dirname)
      File.write(file, "_format_version: '3.0'\n")
      allow(Open3).to receive(:capture3).and_return([ "", "", success ])
    end

    after { FileUtils.rm_f(file) }

    describe ".validate" do
      it "runs the OFFLINE `deck file validate` with the file as a positional argument (no -s, not `gateway`)" do
        expect(described_class.validate(file)).to be(true)

        expect(Open3).to have_received(:capture3).with({}, "deck", "file", "validate", file.to_s)
      end

      it "uses the binary named by DECK_BIN" do
        ENV["DECK_BIN"] = "/opt/deck/deck"

        described_class.validate(file)

        expect(Open3).to have_received(:capture3).with({}, "/opt/deck/deck", "file", "validate", file.to_s)
      end

      it "finds a placeholder in the double-quoted form the tool writes, and in the plain form" do
        text = %(a: "${{ env "DECK_FORM_A" }}"\nb: ${{ env "DECK_FORM_B" }}\nc: 'x ${{ env "DECK_FORM_C" }} y'\n)

        expect(text.scan(described_class::ENV_REFERENCE).flatten).to eq(%w[DECK_FORM_A DECK_FORM_B DECK_FORM_C])
      end

      it "gives every DECK_ variable the file references a harmless dummy, whatever the real environment holds" do
        File.write(file, <<~YAML)
          key: "${{ env "DECK_SPEC_ONE_KEY" }}"
          other: "${{ env "DECK_SPEC_TWO_KEY" }}"
          again: "${{ env "DECK_SPEC_ONE_KEY" }}"
        YAML
        ENV["DECK_SPEC_ONE_KEY"] = "the-real-secret"

        begin
          described_class.validate(file)
        ensure
          ENV.delete("DECK_SPEC_ONE_KEY")
        end

        expect(Open3).to have_received(:capture3).with(
          { "DECK_SPEC_ONE_KEY" => described_class::PLACEHOLDER_VALUE, "DECK_SPEC_TWO_KEY" => described_class::PLACEHOLDER_VALUE },
          "deck", "file", "validate", file.to_s
        )
      end

      it "raises decK's own message, scrubbed of any private key and bounded in length" do
        stderr = "Error: routes.0: name is required\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n#{'x' * 5000}"
        allow(Open3).to receive(:capture3).and_return([ "", stderr, failure ])

        expect { described_class.validate(file) }.to raise_error(described_class::Error) { |error|
          expect(error.message).to include("deck file validate failed", "name is required")
          expect(error.message).not_to include("AAAA")
          expect(error.message.length).to be < 2200
        }
      end

      it "explains a missing binary instead of leaking Errno::ENOENT" do
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

        expect { described_class.validate(file) }.to raise_error(described_class::Error, /wasn't found.*DECK_BIN/m)
      end
    end

    describe ".diff" do
      let(:connection) { build(:kong_connection, admin_url: "https://kong-uat-admin-ro.internal", auth_username: "reader") }
      let(:header) { "Authorization:Basic #{Base64.strict_encode64('reader:pw')}" }

      it "runs `deck gateway diff` with the file positional, against the connection, asking for JSON" do
        allow(Open3).to receive(:capture3).and_return([ { "changes" => { "creating" => [] } }.to_json, "", success ])

        result = described_class.diff(file, connection: connection, secret: "pw")

        expect(result).to eq({ "changes" => { "creating" => [] } })
        expect(Open3).to have_received(:capture3).with(
          {}, "deck", "gateway", "diff", file.to_s,
          "--kong-addr", "https://kong-uat-admin-ro.internal", "--headers", header, "--json-output"
        )
      end

      it "treats blank output as no changes" do
        expect(described_class.diff(file, connection: connection, secret: "pw")).to eq({})
      end

      it "raises decK's message when the diff fails" do
        allow(Open3).to receive(:capture3).and_return([ "", "Error: cannot reach Kong", failure ])

        expect { described_class.diff(file, connection: connection, secret: "pw") }
          .to raise_error(described_class::Error, /deck gateway diff failed: Error: cannot reach Kong/)
      end

      it "raises a fixed decK error, echoing none of the output, when the diff prints something that is not JSON" do
        allow(Open3).to receive(:capture3).and_return([ "not json -----BEGIN PRIVATE KEY-----\nAAAA", "", success ])

        expect { described_class.diff(file, connection: connection, secret: "pw") }
          .to raise_error(described_class::Error, "deck gateway diff did not return JSON") { |e| expect(e.message).not_to include("AAAA") }
      end

      it "sets the same dummy variables for the diff, which substitutes the placeholder too" do
        File.write(file, %(key: "${{ env "DECK_SPEC_DIFF_KEY" }}"\n))

        described_class.diff(file, connection: connection, secret: "pw")

        expect(Open3).to have_received(:capture3).with(
          { "DECK_SPEC_DIFF_KEY" => described_class::PLACEHOLDER_VALUE }, "deck", "gateway", "diff", file.to_s,
          "--kong-addr", anything, "--headers", anything, "--json-output"
        )
      end
    end
  end

  # Opt-in: the calls above are only as right as decK says they are. Set DECK_BIN
  # to a real binary (1.51.1 or 1.66.1) to check them for real.
  describe "against a real decK binary", if: ENV["DECK_BIN"].present? do
    let(:dir) { Dir.mktmpdir }
    let(:pem) { PemFixtures.self_signed(cn: "deckcli.example.internal", days: 30)[:cert_pem] }

    after { FileUtils.remove_entry(dir) }

    def write_yaml(text)
      Pathname(dir).join("kong.yaml").tap { |path| File.write(path, text) }
    end

    it "accepts a valid nested document" do
      path = write_yaml(<<~YAML)
        _format_version: '3.0'
        _info:
          select_tags:
            - team-a
        services:
          - name: orders
            url: http://orders:80
            routes:
              - name: orders-route
                paths:
                  - "/orders"
      YAML

      expect(described_class.validate(path)).to be(true)
    end

    it "rejects an unnamed route with decK's own message" do
      path = write_yaml(<<~YAML)
        _format_version: '3.0'
        _info:
          select_tags:
            - team-a
        services:
          - name: orders
            url: http://orders:80
            routes:
              - paths:
                  - "/orders"
      YAML

      expect { described_class.validate(path) }.to raise_error(described_class::Error, /name is required/)
    end

    it "validates a decK placeholder without the real variable ever being set" do
      ENV.delete("DECK_REAL_SPEC_KEY")
      body = pem.lines.map { |line| "      #{line}" }.join
      path = write_yaml(<<~YAML)
        _format_version: '3.0'
        _info:
          select_tags:
            - team-a
        certificates:
          - id: 11111111-2222-3333-4444-555555555555
            cert: |
        #{body}
            key: "${{ env "DECK_REAL_SPEC_KEY" }}"
      YAML

      expect(described_class.validate(path)).to be(true)
    end
  end
end
