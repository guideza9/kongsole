FactoryBot.define do
  factory :changeset do
    kong_connection do
      association :kong_connection,
        project_env: association(:project_env, name: "uat", apply_mode: "pr", source: "registry", select_tags: %w[managed-by-kongctl])
    end
    status { "open" }
    actor_username { "alice" }
  end
end
