FactoryBot.define do
  factory :kong_entity do
    kong_connection
    entity_type { "service" }
    sequence(:kong_id) { |n| "00000000-0000-0000-0000-#{n.to_s.rjust(12, '0')}" }
    sequence(:name) { |n| "service-#{n}" }
    logical_key { name }
    tags { [] }
    kong_created_at { Time.current }
    kong_updated_at { Time.current }
    enabled { true }
    is_admin_path { false }
    data { {} }
    digest { "digest" }
    first_seen_at { Time.current }
    synced_at { Time.current }
  end
end
