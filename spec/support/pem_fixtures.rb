require "openssl"

# Real, throwaway certificates for specs -- generated, never checked in, and
# never sent anywhere. `days` may be negative to make an already-expired one.
module PemFixtures
  def self.self_signed(cn: "spike.example.internal", days: 90, sans: [], not_before: nil)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = SecureRandom.random_number(2**64)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{cn}/O=Spec")
    cert.public_key = key.public_key
    cert.not_before = not_before || (days.negative? ? Time.now.utc + (days * 86_400) - 86_400 : Time.now.utc - 60)
    cert.not_after = Time.now.utc + (days * 86_400)

    if sans.any?
      ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(ef.create_extension("subjectAltName", sans.map { |s| "DNS:#{s}" }.join(","), false))
    end

    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    { cert_pem: cert.to_pem, key_pem: key.to_pem, der_sha256: OpenSSL::Digest::SHA256.hexdigest(cert.to_der) }
  end
end
