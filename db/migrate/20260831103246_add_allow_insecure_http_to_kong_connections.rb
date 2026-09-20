class AddAllowInsecureHttpToKongConnections < ActiveRecord::Migration[8.1]
  def change
    # The one documented escape hatch from the https:// requirement
    # (docs/DESIGN.md section 3: "skippable only via a flag in the config
    # file, never a UI checkbox"). Deliberately absent from
    # ConnectionsController's permitted params -- only
    # Kong::ConnectionsConfigLoader, reading config/connections.yml, may set it.
    add_column :kong_connections, :allow_insecure_http, :boolean, null: false, default: false
  end
end
