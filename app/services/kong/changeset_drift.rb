module Kong
  # R8.5: has anything moved under a changeset since it began? Two sources,
  # both read-only:
  #   git  -- commits pushed to the base branch since `base_git_sha`. No
  #           base recorded (the repo could not be read when it opened) is
  #           unknown: shown, not blocking. A base no longer in the branch's
  #           history means the branch was rewritten: that counts as moved.
  #   Kong -- update/delete items whose entity Kong now stamps with a
  #           different `updated_at` than when the item was proposed, or no
  #           longer has at all.
  # A submit over any of it needs the person to say they looked.
  class ChangesetDrift
    Report = Struct.new(:commits_behind, :kong_changed, :base_missing, keyword_init: true) do
      # true / false, or nil when no base was recorded (unknown).
      def git_moved?
        return true if base_missing
        return nil if commits_behind.nil?

        commits_behind.positive?
      end

      # What a submit must be acknowledged over.
      def any?
        git_moved? == true || kong_changed.any?
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
      behind = @changeset.base_git_sha.present? ? @git.commits_since(@changeset.base_git_sha) : nil
      Report.new(commits_behind: behind, kong_changed: kong_changed,
        base_missing: @changeset.base_git_sha.present? && behind.nil?)
    end

    private

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
