require "rails_helper"

# The design tokens live in app/assets/tailwind/application.css (@theme). This
# reads the real file, so a token edit that drops below the WCAG floor fails
# here instead of shipping. Pure Ruby -- no rendered page needed.
RSpec.describe "Design token contrast" do
  let(:tokens) do
    File.read(Rails.root.join("app/assets/tailwind/application.css"))
      .scan(/^\s*--color-([\w-]+):\s*(#[0-9a-fA-F]{6})\s*;/).to_h
  end

  def channel(value)
    c = value / 255.0
    c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
  end

  def luminance(hex)
    r, g, b = hex.delete("#").scan(/../).map { |pair| channel(pair.hex) }
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  def contrast(foreground, background)
    light, dark = [ luminance(foreground), luminance(background) ].sort.reverse
    (light + 0.05) / (dark + 0.05)
  end

  it "parses the tokens it asserts on" do
    expect(tokens.keys).to include("bg", "surface", "surface-subtle", "ink-faint", "border-strong")
  end

  it "computes WCAG contrast correctly (black on white is 21:1)" do
    expect(contrast("#000000", "#ffffff")).to be_within(0.001).of(21.0)
  end

  def hue(hex)
    r, g, b = hex.delete("#").scan(/../).map { |pair| pair.hex / 255.0 }
    max, min = [ r, g, b ].max, [ r, g, b ].min
    return 0.0 if max == min

    delta = max - min
    degrees = case max
    when r then ((g - b) / delta) % 6
    when g then ((b - r) / delta) + 2
    else ((r - g) / delta) + 4
    end * 60
    degrees % 360
  end

  # White text on the solid env chip, strip and PR-push button.
  %w[env-uat env-prod].each do |env|
    it "holds white text at 4.5:1 or better on --color-#{env}" do
      expect(contrast(tokens.fetch("env-on"), tokens.fetch(env))).to be >= 4.5
    end
  end

  # uat and prod are told apart by label, rule and shape as well; the colours
  # still have to sit a hue apart, not just a shade, so a misread tone does not
  # turn one into the other.
  it "keeps --color-env-uat and --color-env-prod at least 30 degrees of hue apart" do
    gap = (hue(tokens.fetch("env-uat")) - hue(tokens.fetch("env-prod"))).abs
    gap = 360 - gap if gap > 180

    expect(gap).to be >= 30
  end

  it "keeps the env-coloured title legible on each env's tint" do
    %w[uat prod].each do |env|
      expect(contrast(tokens.fetch("env-#{env}"), tokens.fetch("env-#{env}-tint"))).to be >= 4.5
    end
  end

  # Every chip tone: its label ink on its tint is real text.
  %w[success danger warning caution neutral].each do |tone|
    it "keeps the #{tone} chip label at 4.5:1 or better on its tint" do
      expect(contrast(tokens.fetch("#{tone}-ink"), tokens.fetch("#{tone}-tint"))).to be >= 4.5
    end
  end

  %w[bg surface surface-subtle].each do |surface|
    # Tertiary/meta text is real text: the 4.5:1 body-text floor applies on every surface it sits on.
    it "keeps --color-ink-faint at 4.5:1 or better on --color-#{surface}" do
      expect(contrast(tokens.fetch("ink-faint"), tokens.fetch(surface))).to be >= 4.5
    end

    # Input and button borders identify a control: the 3:1 non-text floor.
    it "keeps --color-border-strong at 3:1 or better on --color-#{surface}" do
      expect(contrast(tokens.fetch("border-strong"), tokens.fetch(surface))).to be >= 3.0
    end
  end
end
