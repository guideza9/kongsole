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
  # A bare host name (or a Kong upstream's name) -- no scheme, port or path.
  HOST_NAME = /\A[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?\z/
  GRPC = %w[grpc grpcs].freeze

  # Kong refuses a tag with a slash (a comma already splits the field).
  def self.tag_errors(tags)
    tags.select { |tag| tag.include?("/") }.map { |tag| "#{tag} can't contain / (Kong refuses it)" }
  end

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
  validate :no_path_on_grpc
  validate :host_is_bare
  validate { self.class.tag_errors(tag_list).each { |message| errors.add(:tags, message) } }
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

  # Kong forwards a gRPC call as it is: its service schema wants no path.
  def no_path_on_grpc
    return unless GRPC.include?(protocol) && path.to_s.strip.present?

    errors.add(:path, "must be empty for a grpc or grpcs service (Kong forwards gRPC calls as they are)")
  end

  def host_is_bare
    value = host.to_s.strip
    return if value.empty? || value.match?(HOST_NAME) || ipv6?(value)

    errors.add(:host, "must be a host name or IP only -- put the port and path in their own fields")
  end

  def ipv6?(value)
    value.include?(":") && IPAddr.new(value.delete_prefix("[").delete_suffix("]")).ipv6?
  rescue IPAddr::InvalidAddressError
    false
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
