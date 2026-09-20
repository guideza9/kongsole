class AddParentKongIdToChangePlans < ActiveRecord::Migration[8.1]
  def change
    # Carries a credential create's owning consumer (or, generally, any
    # entity_type's parent) from propose time through to apply time --
    # docs/DESIGN.md section 15 M3, Kong::EntityTypes' create_path_proc
    # needs it and target_kong_id is nil on a create.
    add_column :change_plans, :parent_kong_id, :uuid
  end
end
