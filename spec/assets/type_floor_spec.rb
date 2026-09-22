require "rails_helper"

# 13px is the smallest text the console sets: it carries state (labels, chips,
# verdicts, gates), so it is not decorative. `--text-xs` is that floor and every
# rule reads it. This reads the real stylesheet and views, so a literal under
# the floor fails here instead of shipping.
RSpec.describe "Type floor" do
  FLOOR_PX = 13.0

  let(:stylesheet) { File.read(Rails.root.join("app/assets/tailwind/application.css")) }

  def rem_to_px(rem)
    rem.to_f * 16
  end

  it "defines --text-xs at the floor" do
    expect(stylesheet).to match(/--text-xs:\s*0\.8125rem;/)
  end

  it "sets no font-size literal under the floor" do
    offenders = stylesheet.scan(/font-size:\s*([\d.]+)(rem|px)/).select do |value, unit|
      (unit == "rem" ? rem_to_px(value) : value.to_f) < FLOOR_PX
    end

    expect(offenders).to be_empty, "Use var(--text-xs) instead of a literal under 13px: #{offenders.map(&:join).uniq.join(', ')}"
  end

  it "sets no arbitrary text size under the floor in a view" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |path|
      File.read(path).scan(/text-\[([\d.]+)px\]/).flatten.select { |px| px.to_f < FLOOR_PX }.map { |px| "#{Pathname(path).relative_path_from(Rails.root)}: #{px}px" }
    end

    expect(offenders).to be_empty
  end

  it "gives every page one page-title h1, never a bare size utility" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{Pathname(path).relative_path_from(Rails.root)}:#{i + 1}" if line.include?("<h1") && line.match?(/text-(xl|2xl|lg)/)
      end
    end

    expect(offenders).to be_empty
  end
end
