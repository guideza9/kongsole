require "rails_helper"

RSpec.describe Kong::DeckRenderer do
  describe ".apply_change" do
    let(:svc_id) { "aaaaaaaa-0000-0000-0000-000000000001" }
    let(:route_id) { "aaaaaaaa-0000-0000-0000-000000000002" }
    let(:up_id) { "aaaaaaaa-0000-0000-0000-000000000003" }
    let(:con_id) { "aaaaaaaa-0000-0000-0000-000000000004" }
    let(:cert_id) { "11111111-2222-3333-4444-555555555555" }
    let(:pem) { "-----BEGIN CERTIFICATE-----\nAAAA\nBBBB\n-----END CERTIFICATE-----\n" }
    let(:doc) { Kong::DeckDocument.parse(nil, select_tags: []) }

    let(:resolver) do
      names = { svc_id => "orders", route_id => "orders-route", up_id => "orders-up", con_id => "reporting-bot" }
      parents = { route_id => svc_id }
      instance_double(Kong::DeckReadModelResolver).tap do |double|
        allow(double).to receive(:name_of) { |id| names[id] }
        allow(double).to receive(:parent_of) { |id| parents[id] }
      end
    end

    # An update carries the diff the planner computes (Kong::ChangePlanner
    # #compute_diff): the fields whose value changed. The renderer writes only those.
    def plan(entity_type:, operation:, before: {}, after: {}, target_kong_id: nil, parent_kong_id: nil, diff: nil)
      diff ||= operation == "update" ? after.reject { |key, value| before.key?(key) && before[key] == value }.to_h { |key, value| [ key, { "from" => before[key], "to" => value } ] } : {}
      ChangePlan.new(entity_type: entity_type, operation: operation, before: before, after: after, diff: diff,
        target_kong_id: target_kong_id, parent_kong_id: parent_kong_id)
    end

    def render_change(**args)
      described_class.apply_change(doc, plan(**args), resolver: resolver)
    end

    describe "services" do
      it "appends a new service on create, leaving out Kong's bookkeeping and nulls" do
        render_change(entity_type: "service", operation: "create",
          after: { "id" => "abc", "created_at" => 1, "updated_at" => 2, "name" => "payments-api", "tags" => [ "payment" ], "client_certificate" => nil })

        expect(doc["services"]).to eq([ { "name" => "payments-api", "tags" => [ "payment" ] } ])
      end

      it "merges attributes into the matched service on update, and a field set to null is removed" do
        doc["services"] = [ { "name" => "payments-api", "tags" => [ "payment" ], "enabled" => true, "path" => "/old" } ]

        render_change(entity_type: "service", operation: "update", before: { "name" => "payments-api" },
          after: { "id" => "abc", "name" => "payments-api", "tags" => %w[payment deprecated], "enabled" => true, "path" => nil })

        expect(doc["services"]).to eq([ { "name" => "payments-api", "tags" => %w[payment deprecated], "enabled" => true } ])
      end

      # Final review #1: an item proposed days ago carries Kong's whole entity as
      # it was then; only what the item changed may be written, or it reverts
      # whatever else changed in git since.
      it "writes only the fields the item changed, leaving the rest of git's entry as it is" do
        doc["services"] = [ { "name" => "payments-api", "url" => "http://pay:80", "retries" => 10, "read_timeout" => 60000 } ]

        render_change(entity_type: "service", operation: "update",
          before: { "name" => "payments-api", "host" => "pay", "port" => 80, "retries" => 5, "read_timeout" => 60000, "tags" => [] },
          after: { "name" => "payments-api", "host" => "pay", "port" => 80, "retries" => 5, "read_timeout" => 30000, "tags" => [] })

        expect(doc["services"]).to eq([ { "name" => "payments-api", "url" => "http://pay:80", "retries" => 10, "read_timeout" => 30000 } ])
      end

      it "refuses, by name, a field git changed since the item was proposed" do
        doc["services"] = [ { "name" => "payments-api", "read_timeout" => 45000 } ]

        expect {
          render_change(entity_type: "service", operation: "update",
            before: { "name" => "payments-api", "read_timeout" => 60000 }, after: { "name" => "payments-api", "read_timeout" => 30000 })
        }.to raise_error(described_class::Unrenderable, /read_timeout of service payments-api changed in git/)
      end

      it "removes the matched service on delete" do
        doc["services"] = [ { "name" => "payments-api" }, { "name" => "keep-me" } ]

        render_change(entity_type: "service", operation: "delete", before: { "name" => "payments-api" })

        expect(doc["services"]).to eq([ { "name" => "keep-me" } ])
      end

      it "deliberately takes a deleted service's nested routes with it" do
        doc["services"] = [ { "name" => "payments-api", "routes" => [ { "name" => "pay-route" } ] }, { "name" => "keep-me" } ]

        render_change(entity_type: "service", operation: "delete", before: { "name" => "payments-api" })

        expect(doc["services"]).to eq([ { "name" => "keep-me" } ])
      end

      it "renames a service onto a free name without leaving an orphan or a duplicate" do
        doc["services"] = [ { "name" => "old-name", "port" => 80 }, { "name" => "other" } ]

        render_change(entity_type: "service", operation: "update", before: { "name" => "old-name" }, after: { "name" => "new-name", "port" => 80 })

        expect(doc["services"]).to eq([ { "name" => "new-name", "port" => 80 }, { "name" => "other" } ])
      end

      it "refuses a rename onto a name another service already has" do
        doc["services"] = [ { "name" => "old-name" }, { "name" => "taken" } ]

        expect {
          render_change(entity_type: "service", operation: "update", before: { "name" => "old-name" }, after: { "name" => "taken" })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /service taken is already in this YAML/)
        expect(doc["services"]).to eq([ { "name" => "old-name" }, { "name" => "taken" } ])
      end

      it "refuses rather than silently no-op when the update target isn't in the YAML" do
        expect {
          render_change(entity_type: "service", operation: "update", before: { "name" => "missing" }, after: { "name" => "missing" })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /no service with name missing in this YAML/)
      end

      it "refuses to create a service that is already there" do
        doc["services"] = [ { "name" => "orders" } ]

        expect { render_change(entity_type: "service", operation: "create", after: { "name" => "orders" }) }
          .to raise_error(Kong::DeckRenderer::Unrenderable, /service orders is already in this YAML/)
      end

      it "raises a Violation subclass, so a refusal surfaces as one rather than a 500" do
        expect { render_change(entity_type: "service", operation: "delete", before: { "name" => "nope" }) }
          .to raise_error(Kong::ChangeGuardrails::Violation)
      end
    end

    describe "routes" do
      before { doc["services"] = [ { "name" => "orders", "url" => "http://orders:80" } ] }

      it "nests a route under its service, dropping the reference to it and any nulls" do
        render_change(entity_type: "route", operation: "create",
          after: { "name" => "orders-route", "paths" => [ "/o" ], "hosts" => nil, "service" => { "id" => svc_id } })

        expect(doc["services"][0]["routes"]).to eq([ { "name" => "orders-route", "paths" => [ "/o" ] } ])
      end

      it "refuses an unnamed route: decK requires a name although Kong's Admin API does not" do
        expect {
          render_change(entity_type: "route", operation: "create", after: { "paths" => [ "/o" ], "service" => { "id" => svc_id } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /a route needs a name to be written into decK YAML/)
      end

      it "refuses a route whose service is not in the YAML, since nesting leaves it nowhere to go" do
        doc["services"] = []

        expect {
          render_change(entity_type: "route", operation: "create", after: { "name" => "r", "service" => { "id" => svc_id } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /the service orders isn't in this YAML/)
      end

      it "refuses a route whose service the read-model cannot name" do
        expect {
          render_change(entity_type: "route", operation: "create",
            after: { "name" => "r", "service" => { "id" => "aaaaaaaa-0000-0000-0000-00000000ffff" } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /can't tell which service this belongs to/)
      end

      it "finds the route to update or delete through its service" do
        doc["services"][0]["routes"] = [ { "name" => "orders-route", "paths" => [ "/o" ] } ]

        render_change(entity_type: "route", operation: "update", before: { "name" => "orders-route", "service" => { "id" => svc_id } },
          after: { "name" => "orders-route", "paths" => [ "/changed" ], "service" => { "id" => svc_id } })
        expect(doc["services"][0]["routes"]).to eq([ { "name" => "orders-route", "paths" => [ "/changed" ] } ])

        render_change(entity_type: "route", operation: "delete", before: { "name" => "orders-route", "service" => { "id" => svc_id } })
        expect(doc["services"][0]["routes"]).to eq([])
      end
    end

    describe "upstreams and targets" do
      it "renders an upstream at the top level" do
        render_change(entity_type: "upstream", operation: "create", after: { "name" => "orders-up", "slots" => 10_000, "host_header" => nil })

        expect(doc["upstreams"]).to eq([ { "name" => "orders-up", "slots" => 10_000 } ])
      end

      it "nests a target under its upstream only, dropping the upstream reference" do
        doc["upstreams"] = [ { "name" => "orders-up" } ]

        render_change(entity_type: "target", operation: "create", parent_kong_id: up_id,
          after: { "target" => "10.0.0.1:80", "weight" => 100, "upstream" => { "id" => up_id }, "tags" => nil })

        expect(doc["upstreams"][0]["targets"]).to eq([ { "target" => "10.0.0.1:80", "weight" => 100 } ])
        expect(doc).not_to have_key("targets")
      end

      it "deletes only the named target" do
        doc["upstreams"] = [ { "name" => "orders-up", "targets" => [ { "target" => "10.0.0.1:80" }, { "target" => "10.0.0.2:80" } ] } ]

        render_change(entity_type: "target", operation: "delete", parent_kong_id: up_id, before: { "target" => "10.0.0.1:80" })

        expect(doc["upstreams"][0]["targets"]).to eq([ { "target" => "10.0.0.2:80" } ])
      end

      it "refuses a target whose upstream is not in the YAML" do
        expect {
          render_change(entity_type: "target", operation: "create", parent_kong_id: up_id, after: { "target" => "10.0.0.1:80" })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /the upstream orders-up isn't in this YAML/)
      end
    end

    describe "consumers" do
      it "renders a consumer by username, leaving out custom_id when it is null" do
        render_change(entity_type: "consumer", operation: "create", after: { "username" => "reporting-bot", "custom_id" => nil, "tags" => nil })

        expect(doc["consumers"]).to eq([ { "username" => "reporting-bot" } ])
      end

      it "updates and deletes by username" do
        doc["consumers"] = [ { "username" => "reporting-bot", "tags" => [ "a" ] } ]

        render_change(entity_type: "consumer", operation: "update", before: { "username" => "reporting-bot" },
          after: { "username" => "reporting-bot", "tags" => [ "b" ] })
        expect(doc["consumers"]).to eq([ { "username" => "reporting-bot", "tags" => [ "b" ] } ])

        render_change(entity_type: "consumer", operation: "delete", before: { "username" => "reporting-bot" })
        expect(doc["consumers"]).to eq([])
      end
    end

    describe "plugins" do
      before do
        doc["services"] = [ { "name" => "orders", "routes" => [ { "name" => "orders-route" } ] } ]
        doc["consumers"] = [ { "username" => "reporting-bot" } ]
      end

      it "puts a global plugin in the top-level list" do
        render_change(entity_type: "plugin", operation: "create",
          after: { "name" => "correlation-id", "service" => nil, "route" => nil, "consumer" => nil, "config" => {} })

        expect(doc["plugins"]).to eq([ { "name" => "correlation-id", "config" => {} } ])
      end

      it "nests a service-scoped plugin under its service, without the scope reference" do
        render_change(entity_type: "plugin", operation: "create",
          after: { "name" => "request-size-limiting", "service" => { "id" => svc_id }, "config" => { "allowed_payload_size" => 8 } })

        expect(doc["services"][0]["plugins"]).to eq([ { "name" => "request-size-limiting", "config" => { "allowed_payload_size" => 8 } } ])
      end

      it "nests a route-scoped plugin under that route, inside its service" do
        render_change(entity_type: "plugin", operation: "create",
          after: { "name" => "rate-limiting", "route" => { "id" => route_id }, "config" => { "minute" => 60 } })

        expect(doc["services"][0]["routes"][0]["plugins"]).to eq([ { "name" => "rate-limiting", "config" => { "minute" => 60 } } ])
      end

      it "nests a consumer-scoped plugin under its consumer" do
        render_change(entity_type: "plugin", operation: "create", after: { "name" => "cors", "consumer" => { "id" => con_id }, "config" => {} })

        expect(doc["consumers"][0]["plugins"]).to eq([ { "name" => "cors", "config" => {} } ])
      end

      # The planner redacts `before` and prunes those marks from `after`, so a
      # secret field Kong holds is simply absent from `after`. It must keep
      # git's value, or `deck gateway sync` would clear it in Kong.
      it "keeps git's value for a nested field that was redacted and left out of the update" do
        env_auth = '${{ env "DECK_LOG_AUTH" }}'
        doc["plugins"] = [ { "name" => "http-log", "config" => {
          "http_endpoint" => '${{ env "DECK_LOG_URL" }}', "headers" => { "Authorization" => env_auth },
          "redis" => { "password" => '${{ env "DECK_REDIS_PW" }}', "host" => "r" }, "timeout" => 1000
        } } ]

        render_change(entity_type: "plugin", operation: "update",
          before: { "name" => "http-log", "config" => { "http_endpoint" => "[REDACTED]", "headers" => "[REDACTED]",
                    "redis" => { "password" => "[REDACTED]", "host" => "r" }, "timeout" => 1000 } },
          after: { "name" => "http-log", "config" => { "redis" => { "host" => "r2" }, "timeout" => 5000 } })

        expect(doc["plugins"][0]["config"]).to eq(
          "http_endpoint" => '${{ env "DECK_LOG_URL" }}', "headers" => { "Authorization" => env_auth },
          "redis" => { "password" => '${{ env "DECK_REDIS_PW" }}', "host" => "r2" }, "timeout" => 5000
        )
      end

      it "still takes a redacted field's new value when the update supplies one" do
        doc["plugins"] = [ { "name" => "aws-lambda", "config" => { "aws_secret" => '${{ env "OLD" }}' } } ]

        render_change(entity_type: "plugin", operation: "update",
          before: { "name" => "aws-lambda", "config" => { "aws_secret" => "[REDACTED]" } },
          after: { "name" => "aws-lambda", "config" => { "aws_secret" => '${{ env "NEW" }}' } })

        expect(doc["plugins"][0]["config"]).to eq("aws_secret" => '${{ env "NEW" }}')
      end

      it "refuses a plugin scoped to more than one entity, which decK YAML cannot express" do
        expect {
          render_change(entity_type: "plugin", operation: "create",
            after: { "name" => "x", "service" => { "id" => svc_id }, "consumer" => { "id" => con_id } })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /scoped to service and consumer can't be written/)
      end

      it "refuses to move a plugin from a service to global, rather than rewriting it under the old scope" do
        doc["services"][0]["plugins"] = [ { "name" => "cors", "config" => {} } ]

        expect {
          render_change(entity_type: "plugin", operation: "update", before: { "name" => "cors", "service" => { "id" => svc_id } },
            after: { "name" => "cors", "service" => nil, "route" => nil, "consumer" => nil, "config" => {} })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /moving a plugin between scopes is not supported in PR mode; delete it and create it again/)
        expect(doc["services"][0]["plugins"]).to eq([ { "name" => "cors", "config" => {} } ])
        expect(doc).not_to have_key("plugins")
      end

      it "refuses to move a plugin from global to a service" do
        doc["plugins"] = [ { "name" => "cors", "config" => {} } ]

        expect {
          render_change(entity_type: "plugin", operation: "update", before: { "name" => "cors", "service" => nil },
            after: { "name" => "cors", "service" => { "id" => svc_id }, "config" => {} })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /moving a plugin between scopes/)
        expect(doc["plugins"]).to eq([ { "name" => "cors", "config" => {} } ])
      end

      it "refuses to move a plugin from one service to another" do
        doc["services"] << { "name" => "billing" }
        other_svc = "aaaaaaaa-0000-0000-0000-0000000000aa"
        doc["services"][0]["plugins"] = [ { "name" => "cors", "config" => {} } ]

        expect {
          render_change(entity_type: "plugin", operation: "update", before: { "name" => "cors", "service" => { "id" => svc_id } },
            after: { "name" => "cors", "service" => { "id" => other_svc }, "config" => {} })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /moving a plugin between scopes/)
        expect(doc["services"][0]["plugins"]).to eq([ { "name" => "cors", "config" => {} } ])
        expect(doc["services"][1]).not_to have_key("plugins")
      end

      it "still updates a plugin whose scope is unchanged, including when the after JSON repeats it" do
        doc["services"][0]["plugins"] = [ { "name" => "cors", "config" => {} } ]
        scope = { "service" => { "id" => svc_id }, "route" => nil, "consumer" => nil }

        render_change(entity_type: "plugin", operation: "update", before: { "name" => "cors" }.merge(scope),
          after: { "name" => "cors", "config" => { "credentials" => true } }.merge(scope))

        expect(doc["services"][0]["plugins"]).to eq([ { "name" => "cors", "config" => { "credentials" => true } } ])
      end

      it "resolves two same-named plugins on different scopes correctly, on update and on delete" do
        doc["services"][0]["plugins"] = [ { "name" => "rate-limiting", "config" => { "minute" => 1 } } ]
        doc["services"][0]["routes"][0]["plugins"] = [ { "name" => "rate-limiting", "config" => { "minute" => 2 } } ]
        service_scope = { "service" => { "id" => svc_id } }
        route_scope = { "route" => { "id" => route_id } }

        render_change(entity_type: "plugin", operation: "update", before: { "name" => "rate-limiting" }.merge(route_scope),
          after: { "name" => "rate-limiting", "config" => { "minute" => 20 } }.merge(route_scope))
        expect(doc["services"][0]["routes"][0]["plugins"]).to eq([ { "name" => "rate-limiting", "config" => { "minute" => 20 } } ])
        expect(doc["services"][0]["plugins"]).to eq([ { "name" => "rate-limiting", "config" => { "minute" => 1 } } ])

        render_change(entity_type: "plugin", operation: "delete", before: { "name" => "rate-limiting" }.merge(service_scope))
        expect(doc["services"][0]["plugins"]).to eq([])
        expect(doc["services"][0]["routes"][0]["plugins"]).to eq([ { "name" => "rate-limiting", "config" => { "minute" => 20 } } ])
      end

      it "finds a plugin to update or delete by name inside its scope" do
        doc["services"][0]["plugins"] = [ { "name" => "request-size-limiting", "config" => { "allowed_payload_size" => 8 } } ]
        scope = { "service" => { "id" => svc_id } }

        render_change(entity_type: "plugin", operation: "update", before: { "name" => "request-size-limiting" }.merge(scope),
          after: { "name" => "request-size-limiting", "config" => { "allowed_payload_size" => 16 } }.merge(scope))
        expect(doc["services"][0]["plugins"][0]["config"]).to eq({ "allowed_payload_size" => 16 })

        render_change(entity_type: "plugin", operation: "delete", before: { "name" => "request-size-limiting" }.merge(scope))
        expect(doc["services"][0]["plugins"]).to eq([])
      end
    end

    describe "certificates, SNIs and CA certificates" do
      let(:vault_key) { "{vault://env/cert-pay-key}" }
      let(:create_after) do
        { "cert" => pem, "cert_alt" => nil, "key" => vault_key, "key_alt" => nil, "snis" => [ "a.example.internal" ], "tags" => [ "team-a" ] }
      end

      it "mints a UUID for a new certificate, writes it as the YAML id, and records it on the plan" do
        cert_plan = plan(entity_type: "certificate", operation: "create", after: create_after)

        described_class.apply_change(doc, cert_plan, resolver: resolver)

        minted = cert_plan.target_kong_id
        expect(minted).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
        expect(doc["certificates"]).to eq([ { "id" => minted, "cert" => pem, "key" => vault_key, "tags" => [ "team-a" ],
                                              "snis" => [ { "name" => "a.example.internal" } ] } ])
      end

      it "passes a decK env placeholder through untouched, for the serializer to double-quote for decK" do
        placeholder = %q(${{ env "DECK_CERT_PAY_KEY" }})

        render_change(entity_type: "certificate", operation: "create", after: create_after.merge("key" => placeholder))

        expect(doc["certificates"][0]["key"]).to eq(placeholder)
        expect(Kong::DeckDocument.serialize(doc)).to include(%q(key: "${{ env "DECK_CERT_PAY_KEY" }}"))
      end

      it "matches a certificate by id on update, keeps the id and the SNI entries it already has" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "key" => vault_key, "tags" => [ "x" ],
                                  "snis" => [ { "name" => "a.example.internal", "tags" => [ "t" ] } ] } ]

        render_change(entity_type: "certificate", operation: "update", target_kong_id: cert_id,
          before: { "id" => cert_id, "tags" => [ "x" ] },
          after: { "id" => cert_id, "tags" => %w[x y], "snis" => [ "a.example.internal", "b.example.internal" ] })

        expect(doc["certificates"]).to eq([ { "id" => cert_id, "cert" => pem, "key" => vault_key, "tags" => %w[x y],
                                              "snis" => [ { "name" => "a.example.internal", "tags" => [ "t" ] }, { "name" => "b.example.internal" } ] } ])
      end

      it "refuses a certificate update when no YAML entry carries its id" do
        doc["certificates"] = [ { "id" => "ffffffff-0000-0000-0000-000000000000", "cert" => pem } ]

        expect {
          render_change(entity_type: "certificate", operation: "update", target_kong_id: cert_id, before: { "id" => cert_id }, after: { "tags" => [ "x" ] })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /no certificate with id #{cert_id} in this YAML/)
      end

      it "deletes a certificate, taking its nested SNIs with it" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "snis" => [ { "name" => "a.example.internal" } ] } ]

        render_change(entity_type: "certificate", operation: "delete", target_kong_id: cert_id, before: { "id" => cert_id })

        expect(doc["certificates"]).to eq([])
      end

      it "nests an SNI under its certificate, matched by the certificate's id" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem } ]

        render_change(entity_type: "sni", operation: "create", parent_kong_id: cert_id,
          after: { "name" => "b.example.internal", "certificate" => { "id" => cert_id }, "tags" => nil })

        expect(doc["certificates"][0]["snis"]).to eq([ { "name" => "b.example.internal" } ])
      end

      it "deletes an SNI, finding its certificate from the SNI's own certificate reference" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "snis" => [ { "name" => "a.example.internal" }, { "name" => "b.example.internal" } ] } ]

        render_change(entity_type: "sni", operation: "delete", before: { "name" => "a.example.internal", "certificate" => { "id" => cert_id } })

        expect(doc["certificates"][0]["snis"]).to eq([ { "name" => "b.example.internal" } ])
      end

      it "refuses an SNI whose certificate is not in the YAML" do
        expect {
          render_change(entity_type: "sni", operation: "create", parent_kong_id: cert_id, after: { "name" => "b.example.internal" })
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /the certificate #{cert_id} isn't in this YAML/)
      end

      it "refuses a certificate create whose id is already in the YAML, leaving exactly one entry" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem } ]

        expect {
          render_change(entity_type: "certificate", operation: "create", target_kong_id: cert_id, after: create_after)
        }.to raise_error(Kong::DeckRenderer::Unrenderable, /certificate #{cert_id} is already in this YAML/)
        expect(doc["certificates"].size).to eq(1)
      end

      it "refuses a CA certificate rename onto cert text another entry has, without echoing the PEM" do
        other_pem = "-----BEGIN CERTIFICATE-----\nCCCC\n-----END CERTIFICATE-----\n"
        doc["ca_certificates"] = [ { "cert" => pem }, { "cert" => other_pem } ]

        expect {
          render_change(entity_type: "ca_certificate", operation: "update", before: { "cert" => pem }, after: { "cert" => other_pem })
        }.to raise_error(Kong::DeckRenderer::Unrenderable) { |error|
          expect(error.message).to eq("ca_certificate with this cert is already in this YAML")
          expect(error.message).not_to include("CCCC")
        }
        expect(doc["ca_certificates"]).to eq([ { "cert" => pem }, { "cert" => other_pem } ])
      end

      it "words a missing CA certificate without repeating itself or echoing the PEM" do
        expect { render_change(entity_type: "ca_certificate", operation: "delete", before: { "cert" => pem }) }
          .to raise_error(Kong::DeckRenderer::Unrenderable, /\Ano ca_certificate with this cert in this YAML/)
      end

      it "renders a CA certificate without an id (decK does not require one)" do
        render_change(entity_type: "ca_certificate", operation: "create", after: { "cert" => pem, "cert_digest" => "abc", "tags" => [ "team-a" ] })

        expect(doc["ca_certificates"]).to eq([ { "cert" => pem, "cert_digest" => "abc", "tags" => [ "team-a" ] } ])
      end

      it "refuses a CA certificate that is already in the YAML, and finds one by its cert text to update or delete" do
        doc["ca_certificates"] = [ { "cert" => pem, "tags" => [ "a" ] } ]

        expect { render_change(entity_type: "ca_certificate", operation: "create", after: { "cert" => pem }) }
          .to raise_error(Kong::DeckRenderer::Unrenderable, /already in this YAML/)

        render_change(entity_type: "ca_certificate", operation: "update", before: { "cert" => pem }, after: { "cert" => pem, "tags" => [ "b" ] })
        expect(doc["ca_certificates"]).to eq([ { "cert" => pem, "tags" => [ "b" ] } ])

        render_change(entity_type: "ca_certificate", operation: "delete", before: { "cert" => pem })
        expect(doc["ca_certificates"]).to eq([])
      end
    end

    describe "moving a child between parents" do
      let(:other_svc) { "aaaaaaaa-0000-0000-0000-0000000000aa" }
      let(:other_up) { "aaaaaaaa-0000-0000-0000-0000000000ab" }
      let(:other_cert) { "11111111-2222-3333-4444-5555555555ff" }

      def untouched(&block)
        snapshot = Marshal.load(Marshal.dump(doc))
        expect(&block).to raise_error(Kong::DeckRenderer::Unrenderable, /moving a .+ between .+s is not supported in PR mode; delete it and create it again/)
        expect(doc).to eq(snapshot)
      end

      it "refuses re-pointing an SNI at another certificate, and leaves the document untouched" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "snis" => [ { "name" => "a.example.internal" } ] } ]

        untouched do
          render_change(entity_type: "sni", operation: "update", parent_kong_id: cert_id,
            before: { "name" => "a.example.internal", "certificate" => { "id" => cert_id } },
            after: { "name" => "a.example.internal", "certificate" => { "id" => other_cert } })
        end
      end

      it "refuses the web-controller shape: parent_kong_id is the current parent, after names the new one" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "snis" => [ { "name" => "a.example.internal" } ] } ]

        untouched do
          render_change(entity_type: "sni", operation: "update", parent_kong_id: cert_id,
            before: { "name" => "a.example.internal" }, after: { "name" => "a.example.internal", "certificate" => { "id" => other_cert } })
        end
      end

      it "refuses a route whose service changes" do
        doc["services"] = [ { "name" => "orders", "routes" => [ { "name" => "orders-route", "paths" => [ "/o" ] } ] } ]

        untouched do
          render_change(entity_type: "route", operation: "update", parent_kong_id: svc_id,
            before: { "name" => "orders-route", "service" => { "id" => svc_id } },
            after: { "name" => "orders-route", "paths" => [ "/o" ], "service" => { "id" => other_svc } })
        end
      end

      it "refuses a route whose service is set to null" do
        doc["services"] = [ { "name" => "orders", "routes" => [ { "name" => "orders-route" } ] } ]

        untouched do
          render_change(entity_type: "route", operation: "update", before: { "name" => "orders-route", "service" => { "id" => svc_id } },
            after: { "name" => "orders-route", "service" => nil })
        end
      end

      it "refuses a target whose upstream changes" do
        doc["upstreams"] = [ { "name" => "orders-up", "targets" => [ { "target" => "10.0.0.1:80" } ] } ]

        untouched do
          render_change(entity_type: "target", operation: "update", parent_kong_id: up_id,
            before: { "target" => "10.0.0.1:80", "upstream" => { "id" => up_id } },
            after: { "target" => "10.0.0.1:80", "weight" => 5, "upstream" => { "id" => other_up } })
        end
      end

      it "still updates a child that keeps its parent, with or without the reference repeated in after" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "snis" => [ { "name" => "a.example.internal" } ] } ]

        render_change(entity_type: "sni", operation: "update", parent_kong_id: cert_id,
          before: { "name" => "a.example.internal", "certificate" => { "id" => cert_id } },
          after: { "name" => "a.example.internal", "certificate" => { "id" => cert_id }, "tags" => [ "t" ] })
        render_change(entity_type: "sni", operation: "update", parent_kong_id: cert_id,
          before: { "name" => "a.example.internal", "certificate" => { "id" => cert_id } }, after: { "name" => "a.example.internal", "tags" => %w[t u] })

        expect(doc["certificates"][0]["snis"]).to eq([ { "name" => "a.example.internal", "tags" => %w[t u] } ])
      end
    end

    describe "ids on update" do
      let(:kong_uuid) { "99999999-0000-0000-0000-000000000009" }
      let(:cases) do
        {
          "service" => {
            doc: { "services" => [ { "name" => "orders" } ] },
            plan: { before: { "name" => "orders" }, after: { "id" => kong_uuid, "name" => "orders", "tags" => [ "x" ] } },
            entry: ->(d) { d["services"][0] }
          },
          "route" => {
            doc: { "services" => [ { "name" => "orders", "routes" => [ { "name" => "orders-route" } ] } ] },
            plan: { before: { "name" => "orders-route", "service" => { "id" => svc_id } },
                    after: { "id" => kong_uuid, "name" => "orders-route", "service" => { "id" => svc_id }, "tags" => [ "x" ] } },
            entry: ->(d) { d["services"][0]["routes"][0] }
          },
          "consumer" => {
            doc: { "consumers" => [ { "username" => "reporting-bot" } ] },
            plan: { before: { "username" => "reporting-bot" }, after: { "id" => kong_uuid, "username" => "reporting-bot", "tags" => [ "x" ] } },
            entry: ->(d) { d["consumers"][0] }
          },
          "plugin" => {
            doc: { "plugins" => [ { "name" => "cors" } ] },
            plan: { before: { "name" => "cors" }, after: { "id" => kong_uuid, "name" => "cors", "config" => {} } },
            entry: ->(d) { d["plugins"][0] }
          },
          "upstream" => {
            doc: { "upstreams" => [ { "name" => "orders-up" } ] },
            plan: { before: { "name" => "orders-up" }, after: { "id" => kong_uuid, "name" => "orders-up", "slots" => 10 } },
            entry: ->(d) { d["upstreams"][0] }
          },
          "target" => {
            doc: { "upstreams" => [ { "name" => "orders-up", "targets" => [ { "target" => "10.0.0.1:80" } ] } ] },
            plan: { parent_kong_id: up_id, before: { "target" => "10.0.0.1:80", "upstream" => { "id" => up_id } },
                    after: { "id" => kong_uuid, "target" => "10.0.0.1:80", "weight" => 5, "upstream" => { "id" => up_id } } },
            entry: ->(d) { d["upstreams"][0]["targets"][0] }
          },
          "sni" => {
            doc: { "certificates" => [ { "id" => cert_id, "cert" => "x", "snis" => [ { "name" => "a.example.internal" } ] } ] },
            plan: { parent_kong_id: cert_id, before: { "name" => "a.example.internal", "certificate" => { "id" => cert_id } },
                    after: { "id" => kong_uuid, "name" => "a.example.internal", "certificate" => { "id" => cert_id }, "tags" => [ "x" ] } },
            entry: ->(d) { d["certificates"][0]["snis"][0] }
          }
        }
      end

      it "does not write Kong's own uuid into an entry that had no id, for any type but a certificate" do
        cases.each do |type, spec|
          spec[:doc].each { |key, value| doc[key] = Marshal.load(Marshal.dump(value)) }

          render_change(entity_type: type, operation: "update", **spec[:plan])

          expect(spec[:entry].call(doc)).not_to have_key("id"), "#{type} update wrote an id"
          expect(Kong::DeckDocument.serialize(doc)).not_to include(kong_uuid), "#{type} update leaked Kong's uuid"
        end
      end

      it "keeps an id the YAML entry already had (hand-authored), and does not replace it with Kong's" do
        cases.each do |type, spec|
          spec[:doc].each { |key, value| doc[key] = Marshal.load(Marshal.dump(value)) }
          spec[:entry].call(doc)["id"] = "hand-authored"

          render_change(entity_type: type, operation: "update", **spec[:plan])

          expect(spec[:entry].call(doc)["id"]).to eq("hand-authored"), "#{type} update lost the existing id"
        end
      end

      it "keeps a certificate's id on update" do
        doc["certificates"] = [ { "id" => cert_id, "cert" => pem, "tags" => [ "x" ] } ]

        render_change(entity_type: "certificate", operation: "update", target_kong_id: cert_id,
          before: { "id" => cert_id }, after: { "id" => cert_id, "tags" => %w[x y] })

        expect(doc["certificates"][0]["id"]).to eq(cert_id)
      end
    end

    describe "credentials" do
      it "are deliberately never rendered (docs/DESIGN.md 1.7), and say so" do
        %w[keyauth_credential basicauth_credential].each do |type|
          expect { render_change(entity_type: type, operation: "create", after: { "key" => "x" }) }
            .to raise_error(NotImplementedError, /#{type} is deliberately never rendered/)
        end
      end

      it "can be checked without a document, so the applier can refuse before touching git" do
        expect { described_class.assert_supported!("keyauth_credential") }.to raise_error(NotImplementedError)
        expect(described_class.assert_supported!("route")).to be_nil
      end
    end

    it "leaves no null, timestamp or parent reference anywhere in what it renders" do
      doc["services"] = [ { "name" => "orders" } ]
      render_change(entity_type: "route", operation: "create", after: {
        "name" => "r", "paths" => [ "/o" ], "hosts" => nil, "headers" => nil, "created_at" => 1, "updated_at" => 2,
        "service" => { "id" => svc_id }, "regex_priority" => 0
      })

      expect(Kong::DeckDocument.serialize(doc)).not_to match(/: null|created_at|updated_at|service:\s*\n\s+id:/)
    end
  end
  # R8.3: one changeset creates a service and a route under it; the route's
  # parent exists only as the earlier item.
  it "nests a route under a service created earlier in the same changeset" do
    changeset = create(:changeset)
    connection = changeset.kong_connection
    provisional = SecureRandom.uuid
    service_plan = create(:change_plan, changeset: changeset, kong_connection: connection, position: 1, apply_mode: "pr",
      operation: "create", entity_type: "service", provisional_kong_id: provisional, target_kong_id: nil,
      after: { "name" => "billing", "host" => "billing.internal", "tags" => %w[managed-by-kongctl] })
    route_plan = create(:change_plan, changeset: changeset, kong_connection: connection, position: 2, apply_mode: "pr",
      operation: "create", entity_type: "route", parent_kong_id: provisional, target_kong_id: nil,
      after: { "name" => "billing-v1", "paths" => %w[/billing], "service" => { "id" => provisional }, "tags" => %w[managed-by-kongctl] })
    doc = Kong::DeckDocument.parse(nil, select_tags: %w[managed-by-kongctl])
    resolver = Kong::ChangesetResolver.new(changeset)

    [ service_plan, route_plan ].each { |plan| described_class.apply_change(doc, plan, resolver: resolver) }
    parsed = YAML.safe_load(Kong::DeckDocument.serialize(doc))

    expect(parsed["services"].map { _1["name"] }).to eq(%w[billing])
    expect(parsed["services"].first["routes"].map { _1["name"] }).to eq(%w[billing-v1])
    expect(parsed["services"].first["routes"].first).not_to have_key("service")
  end
end
