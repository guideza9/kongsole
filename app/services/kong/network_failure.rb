module Kong
  # What kind of network trouble stopped a request (R3). Each project sits on
  # its own network, so "this machine can't reach it" (not on the VPN, DNS
  # does not resolve) must never read as "Kong's Admin API is down".
  module NetworkFailure
    KINDS = %i[dns refused timeout tls other].freeze

    EXCEPTION_RULES = [
      [ :dns, [ SocketError ], /getaddrinfo|name or service not known|nodename nor servname|no such host/i ],
      [ :refused, [ Errno::ECONNREFUSED ], /connection refused/i ],
      [ :timeout, [ Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout ], /execution expired|timed out/i ],
      [ :tls, [ Faraday::SSLError, OpenSSL::SSL::SSLError ], /certificate verify failed|ssl/i ]
    ].freeze

    # Output of decK/git; :auth is git's own failure (a key or token rejected).
    TEXT_RULES = [
      [ :dns, /no such host|could not resolve host/i ],
      [ :refused, /connection refused/i ],
      [ :timeout, %r{i/o timeout|timed out}i ],
      [ :tls, /x509|certificate/i ],
      [ :auth, /permission denied \(publickey\)|authentication failed|could not read username/i ]
    ].freeze

    # Walks the exception and its causes (Faraday wraps the socket error).
    def self.classify(exception)
      chain(exception).each do |error|
        EXCEPTION_RULES.each do |kind, classes, pattern|
          return kind if classes.any? { |klass| error.is_a?(klass) } || pattern.match?(error.message.to_s)
        end
      end
      :other
    end

    def self.classify_text(text)
      TEXT_RULES.find { |_kind, pattern| pattern.match?(text.to_s) }&.first
    end

    def self.chain(exception)
      errors = []
      while exception && !errors.include?(exception)
        errors << exception
        exception = exception.cause || (exception.respond_to?(:wrapped_exception) && exception.wrapped_exception)
      end
      errors
    end
    private_class_method :chain
  end
end
