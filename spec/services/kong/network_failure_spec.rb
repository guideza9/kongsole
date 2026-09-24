require "rails_helper"

RSpec.describe Kong::NetworkFailure do
  {
    Faraday::ConnectionFailed.new(SocketError.new("getaddrinfo: Name or service not known")) => :dns,
    Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new("connect(2)")) => :refused,
    Faraday::TimeoutError.new("execution expired") => :timeout,
    Faraday::SSLError.new("SSL_connect returned=1 errno=0 state=error: certificate verify failed") => :tls,
    Faraday::ConnectionFailed.new("something else") => :other
  }.each do |error, kind|
    it "classifies #{error.class.name.demodulize} (#{error.message[0, 30]}) as #{kind}" do
      expect(described_class.classify(error)).to eq(kind)
    end
  end

  {
    "dial tcp: lookup kong-a-uat.internal: no such host" => :dns,
    "fatal: unable to access 'https://git.example/': Could not resolve host: git.example" => :dns,
    "dial tcp 10.0.0.5:443: connect: connection refused" => :refused,
    "dial tcp 10.0.0.5:443: i/o timeout" => :timeout,
    "x509: certificate signed by unknown authority" => :tls,
    "git@git.example: Permission denied (publickey)." => :auth,
    "deck: unknown flag" => nil
  }.each do |text, kind|
    it "classifies tool output #{text[0, 30].inspect} as #{kind.inspect}" do
      expect(described_class.classify_text(text)).to eq(kind)
    end
  end
end
