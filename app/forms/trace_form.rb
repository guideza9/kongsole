# R5.6: the request a person asks the tracer about. The method is
# `http_method` here (an attribute named `method` would hide Object#method);
# the URL keeps `method=` because that is what people read.
class TraceForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :env, :string
  attribute :http_method, :string, default: "GET"
  attribute :host, :string
  attribute :path, :string

  attr_reader :project

  validates :host, presence: true, length: { maximum: 253 }
  validates :http_method, inclusion: { in: RouteForm::METHODS }
  validates :path, presence: true, length: { maximum: 2048 }, format: { with: %r{\A/}, message: "must start with /" }
  validate :env_of_project

  def initialize(project:, **attrs)
    @project = project
    super(**attrs)
  end

  def submitted?
    [ env, host, path ].any?(&:present?)
  end

  def connection
    @project.project_envs.find_by(name: env)&.kong_connection
  end

  def path_only = path.to_s.split("?", 2).first
  def query = path.to_s.split("?", 2)[1]

  private

  # An env this machine never synced has an empty read-model: tracing it
  # would answer "no route matched" for every request, which is not true.
  def env_of_project
    if connection.nil?
      errors.add(:env, "is not an environment of #{@project.name} with a connection")
    elsif !KongEntity.where(kong_connection: connection).exists?
      errors.add(:env, "has never been synced on this machine, so there is nothing to trace yet")
    end
  end
end
