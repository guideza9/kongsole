# R1.2: every connection belongs to exactly one project env. Existing rows are
# backfilled into project `default` (Kong::LegacyProjectBackfill), keeping
# their credential.
#
# Rollback: `bin/rails db:rollback STEP=1` after removing the R1 code -- the
# project/env link is dropped and connections keep their rows and credentials
# (their names stay `default/<old name>`; rename them or reload the old
# connections.yml if tokens must use the old names).
class AddProjectEnvToKongConnections < ActiveRecord::Migration[8.1]
  def up
    add_reference :kong_connections, :project_env, foreign_key: true, index: { unique: true }
    [ KongConnection, Project, ProjectEnv ].each(&:reset_column_information)
    Kong::LegacyProjectBackfill.call
    change_column_null :kong_connections, :project_env_id, false
  end

  def down
    remove_reference :kong_connections, :project_env, foreign_key: true, index: { unique: true }
  end
end
