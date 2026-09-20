require "rails_helper"

RSpec.describe Kong::ChangeGuardrails do
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
