# R4.10: the real values of a direct-mode plugin plan's secrets, encrypted
# (Active Record Encryption, like kong_connections.auth_secret) and read only
# by Kong::ChangeApplier; the plan's after/diff keep "[REDACTED]". Cleared
# once the plan stops being pending.
#
# Reversible: remove the column. Before a rollback, apply or cancel pending
# plugin plans -- one left pending cannot apply afterwards (the applier
# refuses a body that still says "[REDACTED]" and asks for it to be
# proposed again), so nothing is lost to Kong and no secret is written out.
class AddSealedSecretsToChangePlans < ActiveRecord::Migration[8.1]
  def change
    add_column :change_plans, :sealed_secrets, :text
  end
end
