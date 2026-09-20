require "rails_helper"

RSpec.describe Kong::EntityTypes do
  UP_ID = "aaaaaaaa-0000-0000-0000-000000000001"
  TARGET_ID = "bbbbbbbb-0000-0000-0000-000000000002"

  describe "a flat entity type (service)" do
    let(:definition) { described_class.fetch("service") }

    it "is not nested" do
      expect(definition).not_to be_nested
    end

    it "resolves its collection and member paths without a parent" do
      expect(definition.collection_path).to eq("/services")
      expect(definition.member_path(TARGET_ID)).to eq("/services/#{TARGET_ID}")
    end

    it "ignores a parent id it doesn't need" do
      expect(definition.member_path(TARGET_ID, parent_kong_id: UP_ID)).to eq("/services/#{TARGET_ID}")
    end
  end

  describe "upstream" do
    it "is a flat type with /upstreams as its collection" do
      definition = described_class.fetch("upstream")

      expect(definition).not_to be_nested
      expect(definition.collection_path).to eq("/upstreams")
      expect(definition.member_path(UP_ID)).to eq("/upstreams/#{UP_ID}")
      expect(definition.parent_type).to be_nil
    end
  end

  # Kong 3.7 has no global GET /targets (404 -- verified against the local
  # stack), so a target's list, get, patch, and delete all live under its
  # upstream, unlike credentials, which only nest their create path.
  describe "target" do
    let(:definition) { described_class.fetch("target") }

    it "is nested under an upstream" do
      expect(definition).to be_nested
      expect(definition.parent_type).to eq("upstream")
    end

    it "resolves collection, member, and create paths under the parent upstream" do
      expect(definition.collection_path(parent_kong_id: UP_ID)).to eq("/upstreams/#{UP_ID}/targets")
      expect(definition.member_path(TARGET_ID, parent_kong_id: UP_ID)).to eq("/upstreams/#{UP_ID}/targets/#{TARGET_ID}")
      expect(definition.create_path(parent_kong_id: UP_ID)).to eq("/upstreams/#{UP_ID}/targets")
    end

    it "refuses to build a path without its parent, rather than emitting /upstreams//targets" do
      expect { definition.collection_path }.to raise_error(ArgumentError, /parent_kong_id/)
      expect { definition.member_path(TARGET_ID) }.to raise_error(ArgumentError, /parent_kong_id/)
    end
  end

  # Kong exposes POST /schemas/:name/validate, so a bad healthchecks block is
  # caught at plan time with per-field errors instead of failing at apply.
  describe "schema_name (Kong's /schemas/:name/validate)" do
    it "is set for upstream and target only" do
      expect(described_class.fetch("upstream").schema_name).to eq("upstreams")
      expect(described_class.fetch("target").schema_name).to eq("targets")
    end

    it "is left nil for types M5a doesn't pre-validate, so their behaviour is unchanged" do
      %w[service route consumer plugin keyauth_credential basicauth_credential].each do |type|
        expect(described_class.fetch(type).schema_name).to be_nil
      end
    end
  end

  # A target has no `name` -- its identity is host:port -- so anything that
  # shows an entity to a human (audit trail, commit message, typed-name
  # delete confirmation) resolves it here instead of reading ["name"].
  describe ".label" do
    it "is the entity's name" do
      expect(described_class.label({ "name" => "orders" })).to eq("orders")
    end

    it "is a target's host:port when it has no name" do
      expect(described_class.label({ "target" => "10.0.0.1:8080", "weight" => 100 })).to eq("10.0.0.1:8080")
    end

    it "prefers name over target" do
      expect(described_class.label({ "name" => "n", "target" => "t" })).to eq("n")
    end

    it "takes the first present label across several documents (before, then after)" do
      expect(described_class.label({}, { "target" => "10.0.0.1:8080" })).to eq("10.0.0.1:8080")
      expect(described_class.label(nil, { "name" => "x" })).to eq("x")
    end

    it "is nil when nothing identifies the entity" do
      expect(described_class.label({}, nil)).to be_nil
      expect(described_class.label({ "name" => "" })).to be_nil
    end
  end

  describe "existing credential types" do
    it "keep their flat list path for reads and only nest the create path" do
      definition = described_class.fetch("keyauth_credential")

      expect(definition).not_to be_nested
      expect(definition.member_path(TARGET_ID)).to eq("/key-auths/#{TARGET_ID}")
      expect(definition.create_path(parent_kong_id: UP_ID)).to eq("/consumers/#{UP_ID}/key-auth")
    end
  end
end
