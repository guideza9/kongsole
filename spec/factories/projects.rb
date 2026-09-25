FactoryBot.define do
  factory :project do
    sequence(:key) { |n| "project-#{n}" }
    name { key.titleize }
    source { "local" }
  end
end
