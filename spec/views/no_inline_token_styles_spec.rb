require "rails_helper"

RSpec.describe "view templates" do
  INLINE_TOKEN_STYLE = /style(?:=|:\s*)["'][^"']*var\(--color-/

  it "never restate a design token in an inline style" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].sort.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{Pathname(path).relative_path_from(Rails.root)}:#{i + 1}" if line.match?(INLINE_TOKEN_STYLE)
      end
    end

    expect(offenders).to be_empty,
      "Use the token utilities (text-ink-soft, bg-danger-tint, …) or a component class:\n#{offenders.first(20).join("\n")}"
  end
end
