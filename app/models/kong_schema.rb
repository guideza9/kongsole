# One schema Kong reported for a connection: a plugin's
# (GET /schemas/plugins/<name>) or an entity type's (GET /schemas/<name>).
# Written and read through Kong::SchemaCache; `digest` lets R4 tell when the
# same plugin's schema differs between envs of a project.
class KongSchema < ApplicationRecord
  KINDS = %w[plugin entity].freeze

  belongs_to :kong_connection

  validates :kind, inclusion: { in: KINDS }
  validates :name, :digest, :fetched_at, presence: true

  def self.digest_for(connection:, kind:, name:)
    where(kong_connection: connection, kind: kind, name: name).pick(:digest)
  end

  # Key order is Kong's to choose; the digest is of the content alone.
  def self.digest_of(body)
    Digest::SHA256.hexdigest(JSON.generate(canonical(body)))
  end

  def self.canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
    when Array then value.map { canonical(_1) }
    else value
    end
  end
  private_class_method :canonical
end
