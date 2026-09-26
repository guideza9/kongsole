# R4.1: Kong's schema for a plugin or entity type, cached per connection and
# Kong version (Kong::SchemaCache). A cache only -- every row can be fetched
# again from Kong. Reversible: drop table; nothing refers to it. The
# foreign key cascades so a cached schema never blocks removing a
# connection.
class CreateKongSchemas < ActiveRecord::Migration[8.1]
  def change
    create_table :kong_schemas do |t|
      t.references :kong_connection, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :name, null: false
      t.string :kong_version
      t.string :digest, null: false
      t.jsonb :body, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
    end
    add_index :kong_schemas, %i[kong_connection_id kind name], unique: true
  end
end
