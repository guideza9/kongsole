module Kong
  # R8.5: has anything moved under a changeset since it began? Two sources,
  # both read-only:
  #   git  -- commits pushed to the base branch since `base_git_sha`
  #           (nil when that base cannot be found: unknown, still worth a look);
  #   Kong -- update/delete items whose entity Kong now stamps with a
  #           different `updated_at` than when the item was proposed, or no
  #           longer has at all.
  # A submit over any of it needs the person to say they looked.
  class ChangesetDrift
    Report = Struct.new(:commits_behind, :kong_changed, keyword_init: true) do
      # true / false, or nil when the base could not be found.
      def git_moved?
        commits_behind.nil? ? nil : commits_behind.positive?
      end

      def any?
        git_moved? != false || kong_changed.any?
      end
    end

    def self.check(changeset:, git:, client:)
      new(changeset: changeset, git: git, client: client).check
    end

    def initialize(changeset:, git:, client:)
      @changeset = changeset
      @git = git
      @client = client
    end

    def check
      Report.new(commits_behind: commits_behind, kong_changed: kong_changed)
    end

    private

    def commits_behind
      return nil if @changeset.base_git_sha.blank?

      @git.commits_since(@changeset.base_git_sha)
    end

    def kong_changed
      return [] if @client.nil?

      @changeset.items.where(operation: %w[update delete]).select { |plan| moved?(plan) }
        .map { |plan| { plan_id: plan.id, label: "#{plan.entity_type} #{plan.entity_label}" } }
    end

    def moved?(plan)
      return false if plan.base_updated_at.blank?

      definition = Kong::EntityTypes.fetch(plan.entity_type)
      response = @client.get(definition.member_path(plan.target_kong_id, parent_kong_id: plan.parent_kong_id))
      body = response.body.is_a?(String) ? JSON.parse(response.body) : response.body
      return false if body["updated_at"].blank?

      Time.zone.at(body["updated_at"]).round(3) != plan.base_updated_at.round(3)
    rescue Kong::Client::EntityNotFound
      true
    end
  end
end
