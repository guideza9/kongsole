# R1.3: an env with no apply_mode is read-only -- nothing can be written until
# someone sets it to direct (Kongsole) or pr (connections.yml). The connection
# copies it, so the column must hold NULL and must not default to direct.
#
# Rollback: refuses while any connection has no apply_mode (listing them) --
# rolling back must not turn them into direct. Set their apply_mode first.
class MakeKongConnectionApplyModeNullable < ActiveRecord::Migration[8.1]
  def up
    change_column_default :kong_connections, :apply_mode, from: "direct", to: nil
    change_column_null :kong_connections, :apply_mode, true
  end

  def down
    unset = select_values("SELECT name FROM kong_connections WHERE apply_mode IS NULL")
    if unset.any?
      raise ActiveRecord::IrreversibleMigration,
        "set apply_mode on #{unset.join(', ')} first -- rolling back must not turn them into direct"
    end
    change_column_null :kong_connections, :apply_mode, false
    change_column_default :kong_connections, :apply_mode, from: nil, to: "direct"
  end
end
