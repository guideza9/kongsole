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

  def env_of_project
    errors.add(:env, "is not an environment of #{@project.name} with a connection") unless connection
  end
end
