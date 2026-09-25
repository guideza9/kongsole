module Kong
  # The write-path guardrails from docs/DESIGN.md section 10, step 2
  # (direct-mode column).
  #
  # check_write_access! runs at both propose and apply time (the only thing
  # that gates whether a plan can exist at all). check_delete_confirmation!
  # runs at apply time for a human (proposing has to succeed, so the user
  # reaches ChangePlansController#show and its typed-name field, even
  # though nothing has been typed yet -- the confirmation itself is only
  # collected on the apply request) but at *propose* time for an agent,
  # since an agent delete of a protected entity is never approvable at all
  # -- there is no point handing back a plan_id for it.
  #
  # actor_kind draws the line PRODUCT.md's hard constraints draw: deleting
  # an admin-path or `protected`-tagged entity is a typed-name confirmation
  # for a human (still reversible-by-diligence), but an absolute,
  # no-override block for an agent (MCP) -- confirmation_name isn't even
  # inspected in that case.
  class ChangeGuardrails
    class Violation < StandardError; end

    def self.check_write_access!(connection:)
      # R1.3: an env with no apply_mode is read-only through every path --
      # never read as direct.
      if connection.apply_mode.nil?
        raise Violation, "#{connection.qualified_name || connection.name}: apply mode is not set -- nothing can be " \
          "written until the environment is set to direct (in Kongsole) or pr (in config/connections.yml)"
      end
      return if connection.apply_mode == "pr"
      return if connection.access_level == "rw"

      raise Violation, "this credential can't write (access_level: #{connection.access_level || 'unknown'})"
    end

    # R1.3: a plan runs the way it was proposed (a direct write or a pushed
    # branch). If the env's apply_mode changed while it was pending, running
    # it would either write the Admin API of what is now a PR env (CLAUDE.md
    # rule 1) or push a branch nobody asked for -- so it is refused instead.
    def self.check_plan_mode_current!(plan:, connection:)
      return if plan.apply_mode == connection.apply_mode

      raise Violation, "this plan was proposed for apply mode #{plan.apply_mode}, but " \
        "#{connection.qualified_name || connection.name} is now #{connection.apply_mode || 'not set'} -- re-propose the change"
    end

    def self.check_delete_confirmation!(connection:, entity:, confirmation_name:, actor_kind: "human")
      return unless entity
      return unless protected_entity?(connection, entity) || human_delete_needs_name?(connection, actor_kind)

      entity_name = Kong::EntityTypes.label(entity)

      if actor_kind == "agent"
        raise Violation, "#{entity_name} is admin-path/protected -- it can never be deleted via the agent path, no override"
      end

      if confirmation_name.blank?
        raise Violation, "deleting #{entity_name} requires typing its name to confirm"
      end

      return if confirmation_name == entity_name

      raise Violation, "typed name #{confirmation_name.inspect} does not match #{entity_name.inspect} -- nothing was deleted"
    end

    def self.protected_entity?(connection, entity)
      connection.admin_path?(entity["id"]) || Array(entity["tags"]).include?("protected")
    end

    # At uat/prod (rank >= 2) a human retypes what they are deleting, not just
    # the connection name -- the connection name is the same on every apply
    # and turns into muscle memory. An agent has no typed channel; its
    # rank >= 2 writes are already held to PR mode and review.
    def self.human_delete_needs_name?(connection, actor_kind)
      actor_kind != "agent" && connection.protected_env?
    end

    # docs/DESIGN.md section 15 M4: an admin-route plugin (basic-auth, acl,
    # ip-restriction fronting the tool's own admin path) is read-only, full
    # stop -- stronger than check_delete_confirmation! above, which still
    # lets a human override a typed-name delete. Editing the plugin that
    # *guards* the admin route (e.g. clearing its `allow` list) is at least
    # as dangerous as deleting the route, and fails open with no visible
    # signal that anything changed -- so this is an absolute block on
    # create/update/delete alike, for a human exactly as much as an agent,
    # with no confirmation path at all.
    #
    # `target` is the live entity (update/delete, checked by its own id);
    # `scope_kong_id` is the service/route/consumer a *new* plugin is being
    # attached to (create) -- a plugin can't be admin-path before it exists,
    # but attaching an unrelated plugin to the admin route's own service or
    # route is exactly as capable of breaking it.
    def self.check_plugin_immutable!(connection:, entity_type:, target: nil, scope_kong_id: nil)
      return unless entity_type == "plugin"

      candidate_id = [ target && target["id"], scope_kong_id ].compact.find { |id| connection.admin_path?(id) }
      return unless candidate_id

      raise Violation, "this plugin is on the tool's own admin path -- it is read-only, no override"
    end
  end
end
