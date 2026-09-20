require "openssl"

module Kong
  # Parses a certificate PEM into the metadata the read-model caches --
  # docs/DESIGN.md section 8: "แคชเฉพาะ metadata ของ cert". The PEM itself is
  # not kept. A certificate that will not parse yields { "parse_error" => ... }
  # rather than raising: one bad certificate must never fail a whole sync.
  module CertificateMetadata
    def self.parse(pem)
      return { "parse_error" => "blank" } if pem.to_s.strip.empty?

      cert = OpenSSL::X509::Certificate.new(pem)
      {
        "subject" => cert.subject.to_s(OpenSSL::X509::Name::RFC2253),
        "issuer" => cert.issuer.to_s(OpenSSL::X509::Name::RFC2253),
        "serial" => cert.serial.to_s(16),
        "not_before" => cert.not_before.utc.iso8601,
        "not_after" => cert.not_after.utc.iso8601,
        "fingerprint_sha256" => OpenSSL::Digest::SHA256.hexdigest(cert.to_der),
        "sans" => subject_alt_names(cert)
      }
    rescue OpenSSL::X509::CertificateError, TypeError, ArgumentError => e
      # The class name only -- an OpenSSL message can quote the input.
      { "parse_error" => e.class.name }
    end

    def self.not_after_time(metadata)
      value = metadata && metadata["not_after"]
      value && Time.iso8601(value)
    end

    def self.subject_alt_names(cert)
      extension = cert.extensions.find { |e| e.oid == "subjectAltName" }
      extension ? extension.value.split(/,\s*/) : []
    end
    private_class_method :subject_alt_names
  end
end
