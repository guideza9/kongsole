require "rails_helper"

RSpec.describe PersonalAccessToken do
  describe ".issue!" do
    it "binds to eligible stored-mode connections and returns the raw token exactly once" do
      connection = create(:kong_connection, credential_mode: "stored")

      pat, raw_token = described_class.issue!(
        operator: "alice", issued_by_username: "alice", connection_ids: [ connection.id ]
      )

      expect(raw_token).to start_with("kctl_")
      expect(pat.token_digest).to eq(Digest::SHA256.hexdigest(raw_token))
      expect(pat.token_prefix).to eq(raw_token[0, 12])
      expect(pat.kong_connections).to contain_exactly(connection)
    end

    it "rejects a session-mode connection" do
      connection = create(:kong_connection, credential_mode: "session")

      expect {
        described_class.issue!(operator: "alice", issued_by_username: "alice", connection_ids: [ connection.id ])
      }.to raise_error(PersonalAccessToken::IneligibleConnection, /stored/)

      expect(described_class.count).to eq(0)
    end
  end

  describe ".authenticate" do
    it "returns the matching active token and touches last_used_at" do
      _pat, raw_token = described_class.issue!(operator: "alice", issued_by_username: "alice", connection_ids: [])

      found = described_class.authenticate(raw_token)

      expect(found).to be_present
      expect(found.last_used_at).to be_present
    end

    it "returns nil for a garbage token" do
      expect(described_class.authenticate("not-a-real-token")).to be_nil
    end

    it "returns nil for a revoked token" do
      _pat, raw_token = described_class.issue!(operator: "alice", issued_by_username: "alice", connection_ids: [])
      described_class.active.first.revoke!

      expect(described_class.authenticate(raw_token)).to be_nil
    end

    it "returns nil for a blank token" do
      expect(described_class.authenticate("")).to be_nil
      expect(described_class.authenticate(nil)).to be_nil
    end
  end
end
