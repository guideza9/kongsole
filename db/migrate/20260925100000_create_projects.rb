# R1: a project groups the envs of one Kong estate (its own git repo, its own
# network). Rollback: drop table -- nothing else depends on it until
# AddProjectEnvToKongConnections, which must be rolled back first.
class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.citext :key, null: false
      t.string :name, null: false
      t.string :source, null: false, default: "local"
      t.string :git_repo
      t.string :git_branch
      t.string :git_web_url
      t.integer :delete_threshold, null: false, default: 3
      t.string :network_note
      t.timestamps
    end
    add_index :projects, :key, unique: true
  end
end
