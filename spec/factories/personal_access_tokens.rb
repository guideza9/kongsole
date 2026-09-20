FactoryBot.define do
  factory :personal_access_token do
    operator { "alice" }
    issued_by_username { "alice" }
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("token-#{n}") }
    token_prefix { "kctl_abc123" }

    trait :revoked do
      revoked_at { Time.current }
    end
  end
end
