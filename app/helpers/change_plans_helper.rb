module ChangePlansHelper
  # Fields a plan touches, keyed by operation -- the one definition the summary
  # strip, the Changes table and the Raw JSON line highlighting all read, so
  # they cannot disagree about which fields changed.
  def plan_changed_keys(plan)
    case plan.operation
    when "create" then plan.after.keys
    when "delete" then plan.before.keys
    else plan.diff.keys
    end
  end

  # Who did it, wherever a plan or audit event names an actor: the username, the
  # operator when a shared credential was used, and -- only for an agent -- a
  # "via agent" tag. The agent's username is the person who issued its token, so
  # without the tag an agent's plan reads as that person's own. Human rows stay
  # unmarked, so the tag means something. Takes a ChangePlan or an AuditEvent.
  def actor_summary(record)
    parts = [ record.actor_username ]
    parts << " (as #{record.actor_operator})" if record.actor_operator.present?
    parts << tag.span("via agent", class: "tag ml-1.5") if record.actor_kind == "agent"
    safe_join(parts)
  end

  # Pending PRs' "PR state" cell, in words. The only state the app records today
  # is that the branch was pushed; anything else falls back to its own name.
  PR_STATE_LABELS = { "branch_pushed" => "Branch pushed, awaiting PR" }.freeze

  def pr_state_label(state)
    return "—" if state.blank?

    PR_STATE_LABELS.fetch(state) { state.humanize }
  end

  # Pending PRs' "Branch" cell: the plan's branch, a link into the config repo
  # when the connection has a git URL and plain text when it does not (the same
  # rule as the review page), then the short commit. A plan that never pushed has
  # no branch to show.
  def plan_branch_cell(plan, connection)
    return "—" if plan.pr_state.blank?

    branch = "kongctl/#{plan.id}"
    url = connection.branch_url(branch)
    name = if url
      tag.a(safe_join([ branch, tag.span(" (opens this branch in the config repo, in a new tab)", class: "sr-only") ]),
        href: url, class: "underline underline-offset-2", target: "_blank", rel: "noopener")
    else
      branch
    end
    safe_join([ name, (tag.span(" · #{plan.commit_sha.first(8)}", class: "text-ink-soft") if plan.commit_sha.present?) ])
  end

  # The summary strip's "Changes" cell: a count, what the count is of, and
  # what it means. Never a guess -- a delete says it is permanent because it is.
  def plan_field_summary(plan)
    count = plan_changed_keys(plan).size
    noun = "field".pluralize(count)

    case plan.operation
    when "create" then { count: count, label: "#{noun} added", note: "New #{plan.entity_type.humanize.downcase}" }
    when "delete" then { count: count, label: "#{noun} removed", note: "Permanent" }
    else
      total = plan.after.size
      { count: count, label: "#{noun} changed", note: (count.zero? ? "Nothing differs" : total.positive? ? "of #{total} on the #{plan.entity_type.humanize.downcase}" : "on the #{plan.entity_type.humanize.downcase}") }
    end
  end

  # The one absolute timestamp, anywhere in the console (review page, lists,
  # detail pages, tokens): the same YYYY-MM-DD HH:MM in the viewer's zone. Rendered in UTC
  # because the server cannot know the browser's zone; the local-time
  # controller then rewrites it in the viewer's zone and names that zone,
  # keeping the UTC reading in the tooltip. With JS off the UTC text stands
  # on its own, which is why the zone is spelled out rather than implied.
  UTC_STAMP = "%Y-%m-%d %H:%M UTC"

  def plan_timestamp(time)
    return nil if time.blank?

    utc = time.getutc
    tag.time utc.strftime(UTC_STAMP),
      datetime: utc.iso8601,
      title: utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
      data: { controller: "local-time" }
  end

  # The summary strip's "Expiry" cell. Only a live pending plan has a clock;
  # once a plan is applied, failed or expired the countdown is meaningless, so
  # the cell says what became of it instead. `tone` picks the value's color.
  EXPIRY_SOON = 3.minutes

  def plan_expiry_summary(plan)
    stamp = plan_timestamp(plan.expires_at)

    if plan.status != "pending"
      { value: plan.status.humanize, note: "Expiry no longer applies", tone: nil, iso: nil }
    elsif plan.expired?
      { value: "Expired", note: safe_join([ "#{time_ago_in_words(plan.expires_at)} ago · ", stamp ]), tone: :danger, iso: plan.expires_at.getutc.iso8601 }
    else
      soon = plan.expires_at - Time.current < EXPIRY_SOON
      { value: "in #{time_ago_in_words(plan.expires_at)}", note: stamp, tone: (soon ? :warning : nil), iso: plan.expires_at.getutc.iso8601 }
    end
  end

  # Summary line for the Guardrails cell: what the operator still has to do,
  # then how many checks were already clear.
  def guardrail_summary(guardrails)
    clear = guardrails.count { |g| g.state == :pass }
    confirm = guardrails.count { |g| g.state == :confirm }
    warn = guardrails.count { |g| g.state == :warn }

    value = if confirm.positive? then "#{confirm} to confirm"
    elsif warn.positive? then "#{warn} to review"
    else "All clear"
    end
    tone = warn.positive? ? :warning : nil
    { value: value, note: "#{clear} of #{guardrails.size} passed", tone: tone }
  end
end
