module Kong
  # R8.6: what the CAB reads. The PR description (markdown, for the person to
  # paste into the git host -- Kongsole calls no host API) and the commit
  # message on the pushed branch. Both end in git-trailer form, so the
  # operator behind a shared credential travels with the change
  # (`Changed-by:`, PRODUCT.md "attribution survives shared credentials").
  module PrBody
    module_function

    def markdown(changeset, deck_diff:, gate:, operator:)
      items = changeset.items.to_a
      lines = [
        "## #{changeset.kong_connection.name}: #{pluralize(items.size)}",
        "",
        "| # | Operation | Type | Name |",
        "|---|---|---|---|"
      ]
      items.each { |plan| lines << "| #{plan.position} | #{plan.operation} | #{plan.entity_type} | #{cell(plan.entity_label)} |" }
      lines += [ "", "decK diff: #{deck_summary(deck_diff)}", "", gate_line(gate) ]
      gate.reasons.each { |reason| lines << "- #{reason}" } unless gate.passed?
      (lines + [ "" ] + trailers(changeset, items, operator)).join("\n")
    end

    def commit_message(changeset, operator:)
      items = changeset.items.to_a
      lines = [ "Changeset #{changeset.id}: #{pluralize(items.size)} to #{changeset.kong_connection.name}", "" ]
      items.each { |plan| lines << "- #{plan.operation} #{plan.entity_type} #{plan.entity_label}" }
      (lines + [ "" ] + trailers(changeset, items, operator)).join("\n")
    end

    def trailers(changeset, items, operator)
      lines = [ "Changeset: #{changeset.id}", "Plans: #{items.map(&:id).join(', ')}" ]
      lines << "Changed-by: #{operator}" if operator.present?
      lines
    end

    def deck_summary(deck_diff)
      changes = deck_diff.is_a?(Hash) ? deck_diff["changes"] : nil
      return "not available" unless changes.is_a?(Hash)

      %w[creating updating deleting].map { |bucket| "#{bucket} #{Array(changes[bucket]).size}" }.join(", ")
    end

    def gate_line(gate)
      gate.passed? ? "CI gate: Clear" : "CI gate: Blocked"
    end

    def pluralize(count)
      count == 1 ? "1 change" : "#{count} changes"
    end

    # A name is data from Kong or the operator: a pipe or a line break would
    # break the table row.
    def cell(text)
      text.to_s.gsub("|", "\\|").gsub(/\s*\n\s*/, " ")
    end
  end
end
