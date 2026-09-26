# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_26_100000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "audit_events", force: :cascade do |t|
    t.string "actor_kind", default: "human", null: false
    t.string "actor_operator"
    t.string "actor_username", null: false
    t.bigint "change_plan_id"
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "diff", default: {}, null: false
    t.string "entity_name"
    t.string "entity_type", null: false
    t.bigint "kong_connection_id", null: false
    t.string "operation", null: false
    t.uuid "target_kong_id"
    t.index ["change_plan_id"], name: "index_audit_events_on_change_plan_id"
    t.index ["kong_connection_id", "created_at"], name: "index_audit_events_on_kong_connection_id_and_created_at"
    t.index ["kong_connection_id"], name: "index_audit_events_on_kong_connection_id"
  end

  create_table "change_plans", force: :cascade do |t|
    t.string "actor_kind", default: "human", null: false
    t.string "actor_operator"
    t.string "actor_username", null: false
    t.jsonb "after", default: {}
    t.string "apply_mode", null: false
    t.datetime "base_updated_at"
    t.jsonb "before", default: {}, null: false
    t.bigint "changeset_id"
    t.string "commit_sha"
    t.datetime "created_at", null: false
    t.jsonb "deck_diff"
    t.jsonb "diff", default: {}, null: false
    t.string "entity_type", null: false
    t.datetime "expires_at", null: false
    t.text "failure_reason"
    t.bigint "kong_connection_id", null: false
    t.string "operation", null: false
    t.uuid "parent_kong_id"
    t.integer "position"
    t.integer "pr_number"
    t.string "pr_state"
    t.string "pr_url"
    t.uuid "provisional_kong_id"
    t.bigint "replaces_plan_id"
    t.string "status", default: "pending", null: false
    t.uuid "target_kong_id"
    t.datetime "updated_at", null: false
    t.index ["changeset_id"], name: "index_change_plans_on_changeset_id"
    t.index ["kong_connection_id", "status"], name: "index_change_plans_on_kong_connection_id_and_status"
    t.index ["kong_connection_id"], name: "index_change_plans_on_kong_connection_id"
    t.index ["replaces_plan_id"], name: "index_change_plans_on_replaces_plan_id"
  end

  create_table "changesets", force: :cascade do |t|
    t.string "actor_operator"
    t.string "actor_username", null: false
    t.string "base_git_sha"
    t.string "branch"
    t.string "commit_sha"
    t.datetime "created_at", null: false
    t.jsonb "deck_diff"
    t.text "failure_reason"
    t.jsonb "gate_reasons", default: [], null: false
    t.bigint "kong_connection_id", null: false
    t.text "pr_body"
    t.string "pr_url"
    t.string "status", default: "open", null: false
    t.datetime "submitted_at"
    t.string "submitted_by"
    t.datetime "updated_at", null: false
    t.index ["kong_connection_id"], name: "index_changesets_on_kong_connection_id"
    t.index ["kong_connection_id"], name: "index_changesets_one_open_per_connection", unique: true, where: "((status)::text = 'open'::text)"
  end

  create_table "kong_connections", force: :cascade do |t|
    t.string "access_level"
    t.jsonb "admin_path_fingerprint", default: {}, null: false
    t.string "admin_url", null: false
    t.boolean "allow_insecure_http", default: false, null: false
    t.string "apply_mode"
    t.text "auth_secret"
    t.string "auth_type", default: "basic", null: false
    t.string "auth_username"
    t.string "ca_bundle_path"
    t.string "color_tag", null: false
    t.datetime "created_at", null: false
    t.string "credential_kind", default: "personal"
    t.string "credential_mode", default: "session", null: false
    t.string "env", null: false
    t.string "git_branch"
    t.string "git_path"
    t.string "git_repo"
    t.string "git_web_url"
    t.string "kong_version"
    t.datetime "last_connected_at"
    t.string "last_status"
    t.string "last_sync_status"
    t.datetime "last_synced_at"
    t.string "mode"
    t.string "name", null: false
    t.jsonb "plugins_available", default: {}, null: false
    t.bigint "project_env_id", null: false
    t.integer "rank", null: false
    t.text "select_tags", default: [], array: true
    t.text "shared_usernames", default: [], array: true
    t.integer "sync_interval_seconds", default: 180, null: false
    t.datetime "updated_at", null: false
    t.boolean "verify_ssl", default: true, null: false
    t.boolean "writable", default: true, null: false
    t.index ["env"], name: "index_kong_connections_on_env"
    t.index ["name"], name: "index_kong_connections_on_name", unique: true
    t.index ["project_env_id"], name: "index_kong_connections_on_project_env_id", unique: true
    t.index ["rank"], name: "index_kong_connections_on_rank"
  end

  create_table "kong_entities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.datetime "deleted_at"
    t.string "digest"
    t.boolean "enabled"
    t.string "entity_type", null: false
    t.datetime "first_seen_at", null: false
    t.boolean "is_admin_path", default: false, null: false
    t.bigint "kong_connection_id", null: false
    t.datetime "kong_created_at"
    t.uuid "kong_id", null: false
    t.datetime "kong_updated_at"
    t.citext "logical_key"
    t.citext "name"
    t.datetime "not_after"
    t.uuid "parent_kong_id"
    t.string "parent_type"
    t.datetime "synced_at", null: false
    t.text "tags", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.index ["data"], name: "index_kong_entities_on_data_jsonb_path_ops", opclass: :jsonb_path_ops, using: :gin
    t.index ["kong_connection_id", "entity_type", "kong_created_at", "id"], name: "index_kong_entities_on_connection_type_created", order: { kong_created_at: :desc, id: :desc }
    t.index ["kong_connection_id", "entity_type", "kong_id"], name: "index_kong_entities_on_connection_type_kong_id", unique: true
    t.index ["kong_connection_id", "entity_type", "kong_updated_at", "id"], name: "index_kong_entities_on_connection_type_updated", order: { kong_updated_at: :desc, id: :desc }
    t.index ["kong_connection_id", "entity_type", "name", "id"], name: "index_kong_entities_on_connection_type_name"
    t.index ["kong_connection_id", "entity_type", "not_after"], name: "index_kong_entities_on_connection_type_not_after", where: "(not_after IS NOT NULL)"
    t.index ["kong_connection_id"], name: "index_kong_entities_on_kong_connection_id"
    t.index ["name"], name: "index_kong_entities_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["tags"], name: "index_kong_entities_on_tags", using: :gin
  end

  create_table "kong_schemas", force: :cascade do |t|
    t.jsonb "body", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.datetime "fetched_at", null: false
    t.string "kind", null: false
    t.bigint "kong_connection_id", null: false
    t.string "kong_version"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["kong_connection_id", "kind", "name"], name: "index_kong_schemas_on_kong_connection_id_and_kind_and_name", unique: true
    t.index ["kong_connection_id"], name: "index_kong_schemas_on_kong_connection_id"
  end

  create_table "personal_access_token_connections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "kong_connection_id", null: false
    t.bigint "personal_access_token_id", null: false
    t.datetime "updated_at", null: false
    t.index ["kong_connection_id"], name: "index_personal_access_token_connections_on_kong_connection_id"
    t.index ["personal_access_token_id", "kong_connection_id"], name: "index_pat_connections_uniq", unique: true
    t.index ["personal_access_token_id"], name: "idx_on_personal_access_token_id_cee37572d1"
  end

  create_table "personal_access_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "issued_by_username", null: false
    t.datetime "last_used_at"
    t.string "name"
    t.string "operator", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_personal_access_tokens_on_token_digest", unique: true
  end

  create_table "project_envs", force: :cascade do |t|
    t.string "apply_mode"
    t.string "color_tag"
    t.datetime "created_at", null: false
    t.text "deck_extra_paths", default: [], null: false, array: true
    t.string "git_path"
    t.string "name", null: false
    t.integer "position", null: false
    t.bigint "project_id", null: false
    t.integer "rank", null: false
    t.text "select_tags", default: [], null: false, array: true
    t.string "source", default: "local", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_project_envs_on_project_id_and_name", unique: true
    t.index ["project_id", "position"], name: "index_project_envs_on_project_id_and_position", unique: true
    t.index ["project_id"], name: "index_project_envs_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "delete_threshold", default: 3, null: false
    t.string "git_branch"
    t.string "git_repo"
    t.string "git_web_url"
    t.citext "key", null: false
    t.string "name", null: false
    t.string "network_note"
    t.string "source", default: "local", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_projects_on_key", unique: true
  end

  add_foreign_key "audit_events", "change_plans"
  add_foreign_key "audit_events", "kong_connections"
  add_foreign_key "change_plans", "change_plans", column: "replaces_plan_id"
  add_foreign_key "change_plans", "changesets"
  add_foreign_key "change_plans", "kong_connections"
  add_foreign_key "changesets", "kong_connections"
  add_foreign_key "kong_connections", "project_envs"
  add_foreign_key "kong_entities", "kong_connections"
  add_foreign_key "kong_schemas", "kong_connections", on_delete: :cascade
  add_foreign_key "personal_access_token_connections", "kong_connections"
  add_foreign_key "personal_access_token_connections", "personal_access_tokens"
  add_foreign_key "project_envs", "projects"
end
