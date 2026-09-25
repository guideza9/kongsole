require "rails_helper"

RSpec.describe "Connection switcher data", type: :request do
  it "lists the logged-in project's envs in order, marking the current one and envs with no connection" do
    project = create(:project, key: "project-a")
    dev = create(:project_env, project: project, name: "dev", position: 1)
    create(:project_env, project: project, name: "sit", position: 2)
    uat = create(:project_env, project: project, name: "uat", position: 3)
    current = create(:kong_connection, project_env: dev, admin_url: "https://kong.test")
    create(:kong_connection, project_env: uat)
    sign_in_to(current)

    get health_path
    rows = controller.send(:current_project_envs)
    expect(rows.map { |r| [ r[:env].name, r[:connection].present?, r[:current] ] })
      .to eq([ [ "dev", true, true ], [ "sit", false, false ], [ "uat", true, false ] ])
  end

  it "leaves out envs of other projects" do
    current = create(:kong_connection, admin_url: "https://kong.test")
    create(:kong_connection) # its own project
    sign_in_to(current)

    get health_path
    expect(controller.send(:current_project_envs).map { |r| r[:env] }).to eq([ current.project_env ])
  end

  it "is empty when nobody is logged in" do
    get health_path
    expect(controller.send(:current_project_envs)).to eq([])
  end
end
