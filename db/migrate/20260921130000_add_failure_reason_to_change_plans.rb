# Kong's (or decK's / git's) own words for why an apply failed. Until now the
# message only survived as a one-shot flash on the redirect, so reloading the
# review page -- or a second reviewer opening it -- lost the reason entirely.
# Always written through Kong::CertificateKeyPolicy.scrub: a decK or git error
# can echo a PEM back, and secrets never reach the read-model.
class AddFailureReasonToChangePlans < ActiveRecord::Migration[8.0]
  def change
    add_column :change_plans, :failure_reason, :text
  end
end
