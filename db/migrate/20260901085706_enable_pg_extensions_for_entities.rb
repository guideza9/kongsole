class EnablePgExtensionsForEntities < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"
    enable_extension "pg_trgm"
  end
end
