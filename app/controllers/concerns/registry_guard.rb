# R1: projects, envs and connections loaded from config/connections.yml are
# `registry` rows -- the file is where they change (PR mode can only be set
# there, CLAUDE.md rule 1). The UI refuses to edit them with a 403 that says
# where to go instead.
module RegistryGuard
  extend ActiveSupport::Concern

  private

  def refuse_registry(label)
    @registry_label = label
    render "shared/registry_only", status: :forbidden
  end
end
