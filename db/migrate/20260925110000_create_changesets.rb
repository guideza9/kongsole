# R8.1: a changeset groups the PR-mode plans of one connection into one
# branch and one PR. At most one is open per connection (partial unique
# index). Reversible: drop table -- nothing else refers to it until
# AddChangesetToChangePlans, which rolls back first.
class CreateChangesets < ActiveRecord::Migration[8.1]
  def change
    create_table :changesets do |t|
      t.references :kong_connection, null: false, foreign_key: true
      t.string :status, null: false, default: "open"
      t.string :actor_username, null: false
      t.string :actor_operator
      t.string :base_git_sha
      t.string :branch
      t.string :commit_sha
      t.jsonb :deck_diff
      t.jsonb :gate_reasons, null: false, default: []
      t.text :pr_body
      t.string :pr_url
      t.text :failure_reason
      t.string :submitted_by
      t.datetime :submitted_at
      t.timestamps
    end
    add_index :changesets, :kong_connection_id, unique: true, where: "status = 'open'",
      name: "index_changesets_one_open_per_connection"
  end
end
