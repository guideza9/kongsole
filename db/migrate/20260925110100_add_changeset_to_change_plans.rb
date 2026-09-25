# R8.1: a plan may sit in a changeset, at a position, and a create there gets
# a provisional id its children in the same changeset can name as parent.
# An edited item replaces an earlier plan. Reversible: drops the columns
# (plans keep everything they had before R8).
class AddChangesetToChangePlans < ActiveRecord::Migration[8.1]
  def change
    add_reference :change_plans, :changeset, foreign_key: true
    add_column :change_plans, :position, :integer
    add_column :change_plans, :provisional_kong_id, :uuid
    add_reference :change_plans, :replaces_plan, foreign_key: { to_table: :change_plans }
  end
end
