require "rails_helper"

# R8.3: a parent created earlier in the same changeset has no row in the
# read-model yet -- its name comes from the create item's own body.
RSpec.describe Kong::ChangesetResolver do
  it "names a service that exists only as a create in the same changeset" do
    changeset = create(:changeset)
    service = create(:change_plan, changeset: changeset, operation: "create", entity_type: "service",
      provisional_kong_id: SecureRandom.uuid, after: { "name" => "billing" }, kong_connection: changeset.kong_connection)
    resolver = described_class.new(changeset)
    expect(resolver.name_of(service.provisional_kong_id)).to eq("billing")
  end

  it "gives a created route's parent, for a plugin scoped to it" do
    changeset = create(:changeset)
    service_id = SecureRandom.uuid
    route = create(:change_plan, changeset: changeset, operation: "create", entity_type: "route", provisional_kong_id: SecureRandom.uuid,
      parent_kong_id: service_id, after: { "name" => "billing-v1" }, kong_connection: changeset.kong_connection)
    expect(described_class.new(changeset).parent_of(route.provisional_kong_id)).to eq(service_id)
  end

  it "prefers the read-model for entities that already exist" do
    changeset = create(:changeset)
    entity = create(:kong_entity, kong_connection: changeset.kong_connection, entity_type: "service", name: "ledger")
    expect(described_class.new(changeset).name_of(entity.kong_id)).to eq("ledger")
  end

  it "ignores items no longer in the changeset, and unknown ids" do
    changeset = create(:changeset)
    dropped = create(:change_plan, changeset: changeset, operation: "create", entity_type: "service", status: "cancelled",
      provisional_kong_id: SecureRandom.uuid, after: { "name" => "billing" }, kong_connection: changeset.kong_connection)
    resolver = described_class.new(changeset)
    expect(resolver.name_of(dropped.provisional_kong_id)).to be_nil
    expect(resolver.name_of(nil)).to be_nil
  end
end
