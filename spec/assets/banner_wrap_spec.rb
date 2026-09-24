require "rails_helper"

# A notice banner carries text nobody controls the length of: an admin URL in
# an unreachable-network alert, an operator name in a risk notice. On a 390px
# screen it must wrap inside the banner, never scroll the page sideways (R3,
# Review Focus 5). This reads the real stylesheet.
RSpec.describe "Notice banner wrapping" do
  let(:stylesheet) { File.read(Rails.root.join("app/assets/tailwind/application.css")) }

  it "breaks long unspaced text inside every notice banner" do
    rule = stylesheet[/^\.notice-banner\s*\{[^}]*\}/m]
    expect(rule).to match(/overflow-wrap:\s*anywhere/)
  end
end
