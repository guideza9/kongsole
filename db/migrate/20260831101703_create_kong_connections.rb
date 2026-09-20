class CreateKongConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :kong_connections do |t|
      t.string :name, null: false
      t.string :env, null: false                 # dev | sit | uat | prod (free-form, rank is authoritative)
      t.integer :rank, null: false                # dev=0 sit=1 uat=2 prod=3
      t.string :color_tag, null: false # defaulted from env by KongConnection#default_color_tag_from_env when not given

      t.string :admin_url, null: false            # e.g. https://kong-admin.internal (must be https:// unless localhost)
      t.string :auth_type, null: false, default: "basic" # basic | none | header
      t.string :auth_username
      t.text :auth_secret                          # transparently encrypted via ActiveRecord::Encryption (`stored` credential_mode only); never returned via API

      t.string :credential_kind, default: "personal"  # personal | shared -- detected from consumer tag, see Kong::CredentialClassifier
      t.string :credential_mode, null: false, default: "session" # session | stored
      t.string :access_level                      # rw | ro -- detected from Kong::AccessProbe

      t.boolean :verify_ssl, null: false, default: true
      t.string :ca_bundle_path

      t.string :apply_mode, null: false, default: "direct" # direct | pr
      t.boolean :writable, null: false, default: true

      t.string :git_repo
      t.string :git_branch
      t.string :git_path
      t.text :select_tags, array: true, default: []
      t.text :shared_usernames, array: true, default: [] # fallback classification when the consumer tag can't be read

      t.string :kong_version
      t.string :mode                              # Kong CE deployment mode reported by GET /, e.g. "traditional"
      t.jsonb :plugins_available, null: false, default: {}
      t.jsonb :admin_path_fingerprint, null: false, default: {} # ids of the service/routes/plugins/consumers that form this connection's own entry path

      t.datetime :last_connected_at
      t.string :last_status                       # ok | unauthorized | forbidden | route_not_matched | not_found | rate_limited | unavailable | error

      t.integer :sync_interval_seconds, null: false, default: 180
      t.datetime :last_synced_at
      t.string :last_sync_status

      t.timestamps
    end

    add_index :kong_connections, :name, unique: true
    add_index :kong_connections, :env
    add_index :kong_connections, :rank
  end
end
