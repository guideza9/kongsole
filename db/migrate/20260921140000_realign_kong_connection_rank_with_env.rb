# Rank drives every guardrail (loud chrome, retyped name, re-auth, the MCP
# direct-mode block) and is now always derived from env. Rows saved while it
# was a free-typed field can disagree with their env -- an env=prod row at
# rank 0 has no gate at all -- so realign them once. Data-only; no schema change.
class RealignKongConnectionRankWithEnv < ActiveRecord::Migration[8.1]
  RANKS = { "dev" => 0, "sit" => 1, "uat" => 2, "prod" => 3 }.freeze

  def up
    RANKS.each do |env, rank|
      execute <<~SQL.squish
        UPDATE kong_connections SET rank = #{rank}
        WHERE env = #{quote(env)} AND rank <> #{rank}
      SQL
    end
  end

  def down
    # The previous ranks are not recoverable, and they were the bug.
  end
end
