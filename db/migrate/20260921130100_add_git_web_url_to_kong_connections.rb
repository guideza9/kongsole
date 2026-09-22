# Where a pushed branch can be read in a browser, as a URL *template* holding
# {branch} -- not a base URL. PRODUCT.md still lists the git host as undecided
# ("before M2"), and the four candidates disagree about branch URLs
# (/tree/x, /branch/x, ?version=GBx), so the tool substitutes rather than
# guesses. Blank leaves the branch as plain text, which is the local-bare-repo
# case config/connections.yml ships with.
class AddGitWebUrlToKongConnections < ActiveRecord::Migration[8.0]
  def change
    add_column :kong_connections, :git_web_url, :string
  end
end
