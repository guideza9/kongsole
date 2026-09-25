# R2.2: the "Add route" form, opened under one service. Hosts and paths come
# one per line; methods and protocols as checkbox lists. Checks what Kong
# would refuse (a route that matches nothing, a path that is neither a prefix
# nor a regex, a regex that does not compile) and builds the route body for
# Kong::ChangePlanner, with no key for a matching rule left empty.
class RouteForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  PROTOCOLS = %w[http https grpc grpcs].freeze
  METHODS = %w[GET POST PUT PATCH DELETE OPTIONS HEAD].freeze
  # A wildcard only as the whole leftmost or rightmost label, as Kong allows;
  # an optional port.
  HOST_FORMAT = /\A(?:\*\.)?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*(?:\.\*)?(?::\d{1,5})?\z/

  attribute :name, :string
  attribute :protocols, default: -> { %w[http https] }
  # Not `methods`: that would shadow Object#methods. The form still posts
  # `route_form[methods][]` (the writer below), as the plan's contract names it.
  attribute :http_methods, default: -> { [] }
  attribute :hosts, :string
  attribute :paths, :string
  attribute :strip_path, :boolean, default: true
  attribute :preserve_host, :boolean, default: false
  attribute :tags, :string

  validates :name, presence: true
  validates :name, format: { with: ServiceForm::NAME_FORMAT, message: ServiceForm::NAME_MESSAGE }, allow_blank: true
  validate :protocols_known
  validate :methods_known
  validate :matches_something
  validate :hosts_well_formed
  validate :paths_well_formed
  validate :no_strip_path_on_grpc_only
  validate { ServiceForm.tag_errors(tag_list).each { |message| errors.add(:tags, message) } }

  def methods=(value)
    self.http_methods = value
  end

  def protocols_list = clean_list(protocols)
  def methods_list = clean_list(http_methods).map(&:upcase)
  def hosts_list = lines(hosts)
  def paths_list = lines(paths)

  def to_attributes(select_tags:, service_kong_id:)
    {
      "name" => name.to_s.strip,
      "protocols" => protocols_list,
      "methods" => methods_list.presence,
      "hosts" => hosts_list.presence,
      "paths" => paths_list.presence,
      "strip_path" => strip_path,
      "preserve_host" => preserve_host,
      "tags" => tag_list(select_tags).presence,
      "service" => { "id" => service_kong_id }
    }.compact
  end

  def tag_list(select_tags = [])
    (Array(select_tags) + tags.to_s.split(",")).map(&:strip).reject(&:blank?).uniq
  end

  private

  def clean_list(value)
    Array(value).map { |item| item.to_s.strip }.reject(&:blank?).uniq
  end

  def lines(value)
    value.to_s.split(/\r?\n/).map(&:strip).reject(&:blank?).uniq
  end

  def protocols_known
    list = protocols_list
    errors.add(:protocols, "choose at least one") if list.empty?
    unknown = list - PROTOCOLS
    errors.add(:protocols, "#{unknown.join(', ')} is not a protocol Kong routes") if unknown.any?
  end

  def methods_known
    unknown = methods_list - METHODS
    errors.add(:methods, "#{unknown.join(', ')} is not an HTTP method") if unknown.any?
  end

  def matches_something
    return if methods_list.any? || hosts_list.any? || paths_list.any?

    errors.add(:base, "Add at least one method, host or path, so Kong knows which requests this route takes")
  end

  def hosts_well_formed
    hosts_list.each do |host|
      next if host.match?(HOST_FORMAT) && !(host.start_with?("*.") && host.split(":").first.end_with?(".*"))

      errors.add(:hosts, "#{host} is not a host name (a wildcard may only be the first or last part, like *.example.com)")
    end
  end

  # Kong refuses strip_path on a route that takes only gRPC.
  def no_strip_path_on_grpc_only
    list = protocols_list
    return unless strip_path && list.any? && (list - ServiceForm::GRPC).empty?

    errors.add(:strip_path, "must be off for a route that only takes grpc or grpcs (Kong refuses it)")
  end

  def paths_well_formed
    paths_list.each do |path|
      if path.start_with?("~")
        begin
          Regexp.new(path.delete_prefix("~"))
        rescue RegexpError => e
          errors.add(:paths, "#{path} is not a valid regex: #{e.message}")
        end
      elsif !path.start_with?("/")
        errors.add(:paths, "#{path} must start with / (or ~ for a regex)")
      end
    end
  end
end
