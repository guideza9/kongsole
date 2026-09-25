FactoryBot.define do
  factory :project_env do
    project
    sequence(:name) { |n| "env-#{n}" }
    sequence(:position) { |n| n }
    rank { 0 }
    apply_mode { "direct" }
    source { "local" }
  end
end
