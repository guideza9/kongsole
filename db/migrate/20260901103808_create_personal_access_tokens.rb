class CreatePersonalAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :personal_access_tokens do |t|
      t.string :name
      t.string :operator, null: false
      t.string :issued_by_username, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :personal_access_tokens, :token_digest, unique: true
  end
end
