# A general slot for facts about an audit event that do not deserve a column
# of their own. M5b puts {"acknowledged_env_vars" => [...]} here: which env
# vars an operator (or agent) confirmed exist before a certificate key
# reference was applied. AuditEvent stays append-only (readonly? unchanged).
class AddContextToAuditEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_events, :context, :jsonb, default: {}, null: false
  end
end
