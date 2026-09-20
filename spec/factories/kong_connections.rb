FactoryBot.define do
  factory :kong_connection do
    sequence(:name) { |n| "dev-#{n}" }
    env { "dev" }
    rank { 0 }
    admin_url { "http://127.0.0.1:8001" }
    auth_type { "basic" }
    auth_username { "kongctl" }
    credential_mode { "session" }
    apply_mode { "direct" }
    verify_ssl { true }
    writable { true }

    trait :prod do
      name { "prod" }
      env { "prod" }
      rank { 3 }
      admin_url { "https://kong-prod-admin-ro.internal" }
    end

    trait :shared_credential do
      credential_kind { "shared" }
    end

    trait :stored do
      credential_mode { "stored" }
    end
  end
end
