# The full-document JSON editor's parse/validate/prune step, shared by
# EntitiesController#update (M3 follow-up) and PluginsController#create
# (docs/DESIGN.md section 15 M4) -- both hand the operator's edited JSON
# straight to Kong::ChangePlanner as `attributes`, and both need the same
# three things done to it first: reject anything that isn't a JSON object,
# strip the fields Kong assigns itself, and strip anything secret-named so a
# typed-in credential can never be set from a form (docs/DESIGN.md section 8).
module JsonPayloadParsing
  extend ActiveSupport::Concern

  class InvalidPayload < StandardError; end

  private

  def parse_json_payload!(raw_json, entity_type:)
    parsed = JSON.parse(raw_json)
    unless parsed.is_a?(Hash)
      raise InvalidPayload, "The JSON must be an object (a single entity document), not a #{parsed.class.name.downcase}."
    end

    Kong::Redactor.prune_sensitive(entity_type, parsed.except(*Kong::EntityTypes::KONG_MANAGED_FIELDS))
  rescue JSON::ParserError => e
    # Deliberately not the parser's own message: it quotes a snippet of the
    # source text, which for a certificate form can be key material.
    position = e.message[/line (\d+) column (\d+)/]
    raise InvalidPayload, position ? "That isn't valid JSON (#{position})." : "That isn't valid JSON."
  end
end
