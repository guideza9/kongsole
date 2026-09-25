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
    color_tag { nil }
    git_repo { nil }
    git_branch { nil }
    git_web_url { nil }
    git_path { nil }
    select_tags { [] }

    # R1: env, rank, apply_mode and git settings are copied from the env, so
    # the env is built from whatever the spec asked of the connection. Each
    # connection gets its own project (key = the connection's name), making
    # its name "<name>/<env>".
    project_env do
      association :project_env,
        name: env, rank: rank, apply_mode: apply_mode, color_tag: color_tag,
        source: apply_mode == "pr" ? "registry" : "local",
        git_path: git_path, select_tags: select_tags,
        project: association(:project, key: name.to_s.parameterize.tr("_", "-")[0, 40],
          git_repo: git_repo, git_branch: git_branch, git_web_url: git_web_url)
    end

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
