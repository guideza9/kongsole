class CreatePersonalAccessTokenConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :personal_access_token_connections do |t|
      t.references :personal_access_token, null: false, foreign_key: true
      t.references :kong_connection, null: false, foreign_key: true

      t.timestamps
    end

    add_index :personal_access_token_connections, [ :personal_access_token_id, :kong_connection_id ],
      unique: true, name: "index_pat_connections_uniq"
  end
end
