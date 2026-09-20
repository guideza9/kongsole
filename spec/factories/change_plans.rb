FactoryBot.define do
  factory :change_plan do
    kong_connection
    actor_username { "alice" }
    operation { "update" }
    entity_type { "service" }
    sequence(:target_kong_id) { |n| "11111111-1111-1111-1111-#{n.to_s.rjust(12, '0')}" }
    before { { "id" => target_kong_id, "name" => "payments-api", "tags" => [ "payment" ], "updated_at" => 1_700_000_000 } }
    after { { "id" => target_kong_id, "name" => "payments-api", "tags" => %w[payment deprecated], "updated_at" => 1_700_000_000 } }
    diff { { "tags" => { "from" => [ "payment" ], "to" => %w[payment deprecated] } } }
    apply_mode { "direct" }
    base_updated_at { Time.zone.at(1_700_000_000) }
    status { "pending" }
    expires_at { 15.minutes.from_now }

    trait :delete do
      operation { "delete" }
      after { {} }
      diff { { "operation" => "delete" } }
    end

    trait :expired do
      expires_at { 1.minute.ago }
    end
  end
end
