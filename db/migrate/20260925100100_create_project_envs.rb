# R1: an env of a project, in the project's own order, owning rank and
# apply_mode. Rollback: drop table (roll back AddProjectEnvToKongConnections
# first).
class CreateProjectEnvs < ActiveRecord::Migration[8.1]
  def change
    create_table :project_envs do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :position, null: false
      t.integer :rank, null: false
      t.string :apply_mode            # NULL = not set -> nothing can be written
      t.string :color_tag
      t.string :source, null: false, default: "local"
      t.string :git_path
      t.text :deck_extra_paths, array: true, null: false, default: []
      t.text :select_tags, array: true, null: false, default: []
      t.timestamps
    end
    add_index :project_envs, %i[project_id name], unique: true
    add_index :project_envs, %i[project_id position], unique: true
  end
end
