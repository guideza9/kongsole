require "rails_helper"

RSpec.describe Kong::ChangeGuardrails do
  # A target carries no `name`; a `protected`-tagged one must be confirmed by
  # typing its host:port, not by an impossible blank name.
  describe ".check_delete_confirmation! for a protected target" do
    let(:connection) { create(:kong_connection) }
    let(:target) { { "id" => "cccccccc-0000-0000-0000-00000000000c", "target" => "10.0.0.1:8080", "tags" => [ "protected" ] } }

    it "asks for the host:port when none was typed" do
      expect {
        described_class.check_delete_confirmation!(connection: connection, entity: target, confirmation_name: nil)
      }.to raise_error(Kong::ChangeGuardrails::Violation, /10\.0\.0\.1:8080.*typing/)
    end

    it "accepts the exact host:port" do
      expect {
        described_class.check_delete_confirmation!(connection: connection, entity: target, confirmation_name: "10.0.0.1:8080")
      }.not_to raise_error
    end

    it "rejects a different value" do
      expect {
        described_class.check_delete_confirmation!(connection: connection, entity: target, confirmation_name: "10.0.0.2:8080")
      }.to raise_error(Kong::ChangeGuardrails::Violation, /does not match/)
    end
  end

  describe ".check_delete_confirmation! at uat/prod (rank >= 2)" do
    let(:prod) { create(:kong_connection, :prod) }
    let(:service) { { "id" => "dddddddd-0000-0000-0000-00000000000d", "name" => "checkout-api", "tags" => [] } }

    it "asks a human to retype the entity, even one that is not protected" do
      expect {
        described_class.check_delete_confirmation!(connection: prod, entity: service, confirmation_name: nil)
      }.to raise_error(Kong::ChangeGuardrails::Violation, /checkout-api.*typing/)
    end

    it "accepts the exact entity name" do
      expect {
        described_class.check_delete_confirmation!(connection: prod, entity: service, confirmation_name: "checkout-api")
      }.not_to raise_error
    end

    it "does not ask at dev, where the entity is not protected" do
      expect {
        described_class.check_delete_confirmation!(connection: create(:kong_connection), entity: service, confirmation_name: nil)
      }.not_to raise_error
    end

    it "leaves an agent's delete of an unprotected entity alone: it has no typed channel" do
      expect {
        described_class.check_delete_confirmation!(connection: prod, entity: service, confirmation_name: nil, actor_kind: "agent")
      }.not_to raise_error
    end
  end

  describe ".check_plugin_immutable!" do
    ADMIN_ROUTE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    PLUGIN_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    let(:connection) do
      create(:kong_connection, admin_path_fingerprint: { "route_ids" => [ ADMIN_ROUTE_ID ], "plugin_ids" => [ PLUGIN_ID ] })
    end

    it "is a no-op for any entity_type but plugin, even one on the admin path" do
      expect {
        described_class.check_plugin_immutable!(connection: connection, entity_type: "route", target: { "id" => ADMIN_ROUTE_ID })
      }.not_to raise_error
    end

    it "blocks updating the plugin that fronts the connection's own admin path" do
      expect {
        described_class.check_plugin_immutable!(connection: connection, entity_type: "plugin", target: { "id" => PLUGIN_ID })
      }.to raise_error(Kong::ChangeGuardrails::Violation, /read-only/)
    end

    it "blocks deleting it too, identically" do
      expect {
        described_class.check_plugin_immutable!(connection: connection, entity_type: "plugin", target: { "id" => PLUGIN_ID })
      }.to raise_error(Kong::ChangeGuardrails::Violation, /read-only/)
    end

    it "blocks creating a new plugin scoped to the admin route -- not just editing an existing one" do
      expect {
        described_class.check_plugin_immutable!(connection: connection, entity_type: "plugin", scope_kong_id: ADMIN_ROUTE_ID)
      }.to raise_error(Kong::ChangeGuardrails::Violation, /read-only/)
    end

    it "allows editing an ordinary, non-admin-path plugin" do
      expect {
        described_class.check_plugin_immutable!(connection: connection, entity_type: "plugin", target: { "id" => "cccccccc-cccc-cccc-cccc-cccccccccccc" })
      }.not_to raise_error
    end

    it "allows creating a plugin scoped to an ordinary target, or globally (no scope_kong_id at all)" do
      expect {
        described_class.check_plugin_immutable!(connection: connection, entity_type: "plugin", scope_kong_id: "cccccccc-cccc-cccc-cccc-cccccccccccc")
      }.not_to raise_error
      expect {
        described_class.check_plugin_immutable!(connection: connection, entity_type: "plugin", scope_kong_id: nil)
      }.not_to raise_error
    end
  end
end
