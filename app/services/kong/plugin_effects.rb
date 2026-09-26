module Kong
  # R5.3: what an enabled plugin may do to a traced request before Kong
  # forwards it (R5 spec §4.5). The tracer names these; it never runs them.
  # A custom plugin is always named -- Kongsole cannot know what it does.
  module PluginEffects
    Effect = Struct.new(:kind, :status, keyword_init: true)

    TABLE = {
      "key-auth" => [ :may_stop, 401 ], "basic-auth" => [ :may_stop, 401 ], "jwt" => [ :may_stop, 401 ],
      "hmac-auth" => [ :may_stop, 401 ], "ldap-auth" => [ :may_stop, 401 ], "oauth2" => [ :may_stop, 401 ],
      "acl" => [ :may_stop, 403 ], "ip-restriction" => [ :may_stop, 403 ], "bot-detection" => [ :may_stop, 403 ],
      "rate-limiting" => [ :may_stop, 429 ], "request-size-limiting" => [ :may_stop, 413 ],
      "request-transformer" => [ :may_change, nil ], "pre-function" => [ :may_change, nil ],
      "post-function" => [ :may_change, nil ], "proxy-cache" => [ :may_answer, nil ]
    }.freeze

    def self.for(name, config: {})
      if name == "request-termination"
        return Effect.new(kind: config.to_h["trigger"].present? ? :may_answer : :answers, status: config.to_h["status_code"] || 503)
      end

      kind, status = TABLE[name]
      return Effect.new(kind: kind, status: status) if kind
      return nil if Kong::PluginCatalog.bundled.include?(name)

      Effect.new(kind: :unknown, status: nil)
    end
  end
end
