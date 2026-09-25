# Logs a request spec into a connection the way a browser does: WebMock
# answers the version check, the write-access probe, the consumer lookup and
# the admin-path route list (as spec/requests/plugins_spec.rb#sign_in does),
# then POSTs the login form. access: :rw or :ro decides what the probe says.
module SignInHelper
  PROBE_REPLIES = {
    rw: { message: "Not found" },                        # the route matched: this credential can write
    ro: { message: "no Route matched with those values" } # the rw route is not open to it
  }.freeze

  def sign_in_to(connection, access: :rw, username: "alice")
    base = connection.admin_url.chomp("/")
    stub_request(:get, "#{base}/").to_return(status: 200, body: { version: "3.7.0" }.to_json)
    stub_request(:patch, "#{base}#{Kong::AccessProbe::PROBE_PATH}")
      .to_return(status: 404, body: PROBE_REPLIES.fetch(access).to_json)
    stub_request(:get, "#{base}/consumers/#{username}").to_return(status: 200, body: { tags: [] }.to_json)
    stub_request(:get, "#{base}/routes").to_return(status: 200, body: { data: [], offset: nil }.to_json)
    post login_connection_path(connection), params: { username: username, password: "pw" }
  end
end
