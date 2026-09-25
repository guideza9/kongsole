module Kong
  # R8.3: names parents for Kong::DeckRenderer while it renders a changeset.
  # Same duck type as DeckReadModelResolver (`name_of`, `parent_of`): an
  # entity Kong already has is read from the read-model; one created earlier
  # in this changeset has no row yet, so its create item answers instead --
  # matched by the provisional id the planner gave it, named from its body.
  # Only items still in the changeset count; an unknown id answers nil.
  class ChangesetResolver
    def initialize(changeset)
      @changeset = changeset
      @read_model = Kong::DeckReadModelResolver.new(changeset.kong_connection)
    end

    def name_of(kong_id)
      @read_model.name_of(kong_id) || created_name(kong_id)
    end

    def parent_of(kong_id)
      @read_model.parent_of(kong_id) || created(kong_id)&.parent_kong_id
    end

    private

    def created_name(kong_id)
      plan = created(kong_id)
      return nil unless plan

      plan.after[Kong::EntityTypes.fetch(plan.entity_type).deck_key]
    end

    def created(kong_id)
      return nil if kong_id.blank?

      @changeset.items.find_by(operation: "create", provisional_kong_id: kong_id)
    end
  end
end
