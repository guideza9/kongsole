require "rails_helper"

# detailed_hints? is the controller's helper_method, so the bare helper view
# has no such method to verify a stub against.
RSpec.describe HintsHelper, type: :helper do
  before do
    I18n.backend.store_translations(:en, hints: { fields: { demo: { host: {
      help: "Where Kong sends the request.", example: "payments.internal", detail: "Longer explanation." } } } })
  end

  it "renders help and example, linked by id for aria-describedby" do
    without_partial_double_verification { allow(helper).to receive(:detailed_hints?).and_return(true) }
    html = helper.field_hint(:demo, :host, id: "demo-host-hint")
    expect(html).to include('id="demo-host-hint"', "Where Kong sends the request.", "payments.internal", "Longer explanation.")
  end

  it "drops only the detail in compact mode -- help and example always stay" do
    without_partial_double_verification { allow(helper).to receive(:detailed_hints?).and_return(false) }
    html = helper.field_hint(:demo, :host, id: "x")
    expect(html).to include("payments.internal")
    expect(html).not_to include("Longer explanation.")
  end
end
