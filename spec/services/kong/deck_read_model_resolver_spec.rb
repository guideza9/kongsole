require "rails_helper"

RSpec.describe Kong::DeckReadModelResolver do
  let(:connection) { create(:kong_connection) }
  let(:other_connection) { create(:kong_connection) }
  let(:svc_id) { "aaaaaaaa-0000-0000-0000-000000000001" }
  let(:route_id) { "aaaaaaaa-0000-0000-0000-000000000002" }

  before do
    create(:kong_entity, kong_connection: connection, entity_type: "service", kong_id: svc_id, name: "orders")
    create(:kong_entity, kong_connection: connection, entity_type: "route", kong_id: route_id, name: "orders-route",
      parent_type: "service", parent_kong_id: svc_id)
  end

  subject(:resolver) { described_class.new(connection) }

  it "names an entity the way decK YAML does" do
    expect(resolver.name_of(svc_id)).to eq("orders")
  end

  it "finds the parent of a child" do
    expect(resolver.parent_of(route_id)).to eq(svc_id)
  end

  it "answers nil for an id the read-model does not hold, or that is not an id at all" do
    expect(resolver.name_of("aaaaaaaa-0000-0000-0000-00000000ffff")).to be_nil
    expect(resolver.name_of("not-a-uuid")).to be_nil
    expect(resolver.name_of(nil)).to be_nil
    expect(resolver.parent_of("")).to be_nil
  end

  it "never answers for another connection's entity" do
    expect(described_class.new(other_connection).name_of(svc_id)).to be_nil
  end

  it "ignores a soft-deleted entity" do
    KongEntity.find_by!(kong_id: svc_id).update!(deleted_at: Time.current)

    expect(resolver.name_of(svc_id)).to be_nil
  end

  it "copes with no connection at all" do
    expect(described_class.new(nil).name_of(svc_id)).to be_nil
  end
end
