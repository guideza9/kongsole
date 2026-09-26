require "rails_helper"

RSpec.describe Kong::SchemaMismatch do
  it "lists other envs in the project whose cached schema for the plugin differs" do
    project = create(:project, key: "project-a")
    dev = create(:kong_connection, kong_version: "3.7.1", project_env: create(:project_env, project: project, name: "dev", position: 1))
    uat = create(:kong_connection, kong_version: "3.8.0", project_env: create(:project_env, project: project, name: "uat", position: 2))
    sit = create(:kong_connection, kong_version: "3.7.1", project_env: create(:project_env, project: project, name: "sit", position: 3))
    other_project = create(:kong_connection, kong_version: "3.9.0")
    { dev => "aaa", uat => "bbb", sit => "aaa", other_project => "ccc" }.each do |conn, digest|
      KongSchema.create!(kong_connection: conn, kind: "plugin", name: "rate-limiting", kong_version: conn.kong_version,
        digest: digest, body: {}, fetched_at: Time.current)
    end

    expect(described_class.for(connection: dev, plugin_name: "rate-limiting")).to eq([ { env: "uat", kong_version: "3.8.0" } ])
  end

  it "says nothing when no other env has cached that plugin yet" do
    connection = create(:kong_connection)
    expect(described_class.for(connection: connection, plugin_name: "cors")).to eq([])
  end

  it "says nothing when this connection has not cached the plugin itself" do
    project = create(:project)
    dev = create(:kong_connection, project_env: create(:project_env, project: project, name: "dev", position: 1))
    uat = create(:kong_connection, kong_version: "3.8.0", project_env: create(:project_env, project: project, name: "uat", position: 2))
    KongSchema.create!(kong_connection: uat, kind: "plugin", name: "cors", kong_version: "3.8.0", digest: "b", body: {}, fetched_at: Time.current)
    expect(described_class.for(connection: dev, plugin_name: "cors")).to eq([])
  end
end
