module Kong
  # Turns an error from the Kong Admin API (or the network on the way to it)
  # into what the operator needs: a title, the likely cause and what to do
  # next, read from hints.errors.<key> in config/locales/hints.en.yml (R3).
  # A network problem gets the project's network note (R1) on its next step.
  class ErrorExplanation
    Result = Struct.new(:key, :title, :cause, :next_step, keyword_init: true) do
      def to_flash
        { "key" => key, "title" => title, "cause" => cause, "next_step" => next_step }
      end
    end

    KEYS_BY_CLASS = {
      Kong::Client::Unauthorized => "unauthorized",
      Kong::Client::Forbidden => "forbidden",
      Kong::Client::RouteNotMatched => "route_not_matched",
      Kong::Client::EntityNotFound => "entity_not_found",
      Kong::Client::RateLimited => "rate_limited",
      Kong::Client::UpstreamUnavailable => "upstream_unavailable",
      Kong::Client::UnexpectedResponse => "unexpected_response"
    }.freeze

    KEYS_BY_NETWORK_KIND = {
      dns: "network_dns_failed",
      refused: "network_refused",
      timeout: "network_timed_out",
      tls: "network_tls_failed"
    }.freeze

    def self.for(error, network_note: nil)
      key = key_for(error)
      scope = "hints.errors.#{key}"
      next_step = I18n.t("#{scope}.next_step")
      next_step = "#{next_step} #{network_note}" if network_note.present? && network_key?(key)

      Result.new(key: key, title: I18n.t("#{scope}.title"), cause: I18n.t("#{scope}.cause"), next_step: next_step)
    end

    def self.key_for(error)
      case error
      when Kong::Client::NetworkUnreachable then network_key(error.kind)
      when Faraday::Error then network_key(Kong::NetworkFailure.classify(error))
      else KEYS_BY_CLASS.fetch(error.class) { "connection_failed" }
      end
    end
    private_class_method :key_for

    def self.network_key(kind)
      KEYS_BY_NETWORK_KIND.fetch(kind, "connection_failed")
    end
    private_class_method :network_key

    def self.network_key?(key)
      key.start_with?("network_") || key == "connection_failed"
    end
    private_class_method :network_key?
  end
end
