FactoryBot.define do
  factory :audit_event do
    kong_connection
    actor_username { "alice" }
    operation { "update" }
    entity_type { "service" }
    sequence(:target_kong_id) { |n| "22222222-2222-2222-2222-#{n.to_s.rjust(12, '0')}" }
    entity_name { "payments-api" }
    diff { { "tags" => { "from" => [ "payment" ], "to" => %w[payment deprecated] } } }
  end
end
