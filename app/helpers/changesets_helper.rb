# R8.9: words and shapes for the changeset pages.
module ChangesetsHelper
  STATUS_WORDS = { "open" => "Open", "submitted" => "Pushed", "abandoned" => "Abandoned" }.freeze

  def changeset_status_label(changeset)
    STATUS_WORDS.fetch(changeset.status, changeset.status.humanize)
  end

  # "2 create · 1 update": what the items do, in the order the operations
  # read (create, update, delete), counted.
  def changeset_operations_summary(items)
    counts = items.map(&:operation).tally
    %w[create update delete].filter_map { |op| "#{counts[op]} #{op}" if counts[op] }.join(" · ")
  end

  # The nav entry of a PR-mode connection: the open changeset, with how many
  # items wait in it, or the list when nothing is open.
  def changeset_nav_path(open_changeset)
    open_changeset ? changeset_path(open_changeset) : changesets_path
  end

  def changeset_nav_label(open_changeset)
    return "Changeset" unless open_changeset

    safe_join([ "Changeset", " ", content_tag(:span, open_changeset.items.count, class: "nav-count") ])
  end

  def changeset_items_label(count)
    count == 1 ? "1 change" : "#{count} changes"
  end

  # A unified diff as typed lines: the sign stays in the text, so an added or
  # removed line reads as such without its colour. Git's own headers (diff,
  # index, ---/+++) are the file's, not the change's, and are left out.
  def yaml_diff_lines(diff)
    diff.to_s.lines.filter_map do |line|
      next if line.start_with?("diff --git", "index ", "--- ", "+++ ", "new file mode")

      kind = case line[0]
             when "+" then :add
             when "-" then :del
             when "@" then :hunk
             else :context
             end
      [ kind, line.chomp ]
    end
  end

  # The environment variables the items' certificates make Kong read -- the
  # person confirms they are set before submitting (M5b).
  def changeset_env_vars(items)
    items.flat_map { |item| Kong::CertificateKeyPolicy.env_vars_for(item) }.uniq
  end

  # What the drift report says about git, in words; nil when git did not move.
  def changeset_git_drift(drift)
    case drift&.git_moved?
    when nil then "unknown -- the config repo could not be read when this changeset began"
    when true
      if drift.commits_behind
        "#{drift.commits_behind} #{drift.commits_behind == 1 ? 'commit' : 'commits'} pushed to the base branch since this began"
      else
        "the base branch was rewritten since this began"
      end
    end
  end
end
