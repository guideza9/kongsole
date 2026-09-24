require "rails_helper"
require "rake"

RSpec.describe "hints:todo" do
  before(:all) { Rails.application.load_tasks }

  it "lists every hint still marked To Edit, by key" do
    I18n.backend.store_translations(:en, hints: { fields: { demo: { x: { help: "To Edit: check this" } } } })
    expect { Rake::Task["hints:todo"].execute }.to output(/hints\.fields\.demo\.x\.help/).to_stdout
  end
end
