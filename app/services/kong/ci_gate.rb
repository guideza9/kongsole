module Kong
  # The CI gate docs/DESIGN.md section 6 step 6 and section 15 (M2) call
  # for: block a PR-mode change if it touches an admin-path entity, or if it
  # deletes more than a threshold number of entities. Deliberately host-
  # agnostic (no GitHub/GitLab-specific check API) since the git host isn't
  # chosen yet (PRODUCT.md "before M2") -- this is the pure decision logic;
  # `bin/deck-ci-gate` is the thin CLI wrapper a future CI pipeline calls.
  class CiGate
    class Blocked < StandardError; end

    DEFAULT_DELETE_THRESHOLD = 3

    Result = Struct.new(:passed, :reasons, keyword_init: true) do
      def passed? = passed
    end

    def self.check(deck_diff:, admin_path_names:, delete_threshold: nil)
      new(deck_diff: deck_diff, admin_path_names: admin_path_names, delete_threshold: delete_threshold).check
    end

    def initialize(deck_diff:, admin_path_names:, delete_threshold: nil)
      @deck_diff = deck_diff || {}
      @admin_path_names = Array(admin_path_names)
      @delete_threshold = delete_threshold || (ENV["KONG_CI_DELETE_THRESHOLD"] || DEFAULT_DELETE_THRESHOLD).to_i
    end

    def check
      reasons = []
      reasons << admin_path_reason if touches_admin_path?
      reasons << delete_threshold_reason if delete_count > @delete_threshold

      Result.new(passed: reasons.empty?, reasons: reasons)
    end

    private

    def entity_changes
      Array(@deck_diff["changes"] || @deck_diff["entity_changes"])
    end

    def touches_admin_path?
      entity_changes.any? { |change| @admin_path_names.include?(change["name"]) }
    end

    def delete_count
      entity_changes.count { |change| change["new"].nil? || change["change"] == "delete" }
    end

    def admin_path_reason
      "touches an entity on the tool's own admin path -- never allowed, no override"
    end

    def delete_threshold_reason
      "deletes #{delete_count} entities, over the threshold of #{@delete_threshold}"
    end
  end
end
