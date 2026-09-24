namespace :kong do
  desc "Scrub plugin secrets already stored in the read-model, change plans and audit diffs (T0.3)"
  task redact_stored_plugin_secrets: :environment do
    counts = Kong::StoredPluginRedaction.call
    puts "rows changed -- entities: #{counts[:entities]}, plans: #{counts[:plans]}, audit_events: #{counts[:audit_events]}"
  end
end
