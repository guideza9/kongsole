# R2.1: the "New service" form. Takes what a person typed (every value a
# string), checks it the way Kong would, and builds the body Kong::ChangePlanner
# proposes -- typed values, the connection's select_tags, and no key for an
# optional field left empty (decK rejects an explicit null).
class ServiceForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  PROTOCOLS = %w[http https grpc grpcs].freeze
  DEFAULT_PORTS = { "http" => 80, "https" => 443, "grpc" => 80, "grpcs" => 443 }.freeze
  # The characters Kong accepts in a service or route name.
  NAME_FORMAT = /\A[A-Za-z0-9._~-]+\z/
  NAME_MESSAGE = "must use letters, digits, . _ ~ -".freeze
  TIMEOUT_RANGE = (1..2_147_483_646)
  TIMEOUT_FIELDS = %i[connect_timeout read_timeout write_timeout].freeze

  attribute :name, :string
  attribute :protocol, :string, default: "http"
  attribute :host, :string
  attribute :port, :string
  attribute :path, :string
  attribute :retries, :string, default: "5"
  attribute :connect_timeout, :string, default: "60000"
  attribute :read_timeout, :string, default: "60000"
  attribute :write_timeout, :string, default: "60000"
  attribute :enabled, :boolean, default: true
  attribute :tags, :string

  validates :name, presence: true
  validates :name, format: { with: NAME_FORMAT, message: NAME_MESSAGE }, allow_blank: true
  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :host, presence: true
  validate :path_starts_with_slash
  validate { check_range(:port, 1..65_535, blank_ok: true) }
  validate { check_range(:retries, 0..32_767) }
  validate { TIMEOUT_FIELDS.each { |field| check_range(field, TIMEOUT_RANGE) } }

  def to_attributes(select_tags:)
    body = {
      "name" => name.to_s.strip,
      "protocol" => protocol,
      "host" => host.to_s.strip,
      "port" => port_value,
      "path" => path.to_s.strip.presence,
      "retries" => Integer(retries, 10),
      "enabled" => enabled
    }
    TIMEOUT_FIELDS.each { |field| body[field.to_s] = Integer(public_send(field), 10) }
    body["tags"] = tag_list(select_tags).presence
    body.compact
  end

  def tag_list(select_tags = [])
    (Array(select_tags) + tags.to_s.split(",")).map(&:strip).reject(&:blank?).uniq
  end

  private

  def port_value
    port.to_s.strip.present? ? Integer(port, 10) : DEFAULT_PORTS.fetch(protocol, 80)
  end

  def path_starts_with_slash
    value = path.to_s.strip
    errors.add(:path, "must start with /") if value.present? && !value.start_with?("/")
  end

  def check_range(field, range, blank_ok: false)
    raw = public_send(field).to_s.strip
    return if raw.empty? && blank_ok

    number = Integer(raw, 10, exception: false)
    if number.nil?
      errors.add(field, "must be a whole number")
    elsif !range.cover?(number)
      errors.add(field, "must be between #{range.min} and #{range.max}")
    end
  end
end
