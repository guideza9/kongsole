# R1.18: narrows the connections page to the projects a query names.
#
# The query is split on whitespace; every term has to appear (case-insensitive,
# anywhere in the word) in the project's name or key, or in one of its env
# names. The envs a term matched are returned too, so the page can point at
# them ("pay uat" -> Payments, and its uat env). Projects are counted in tens,
# so this runs in memory over the already-loaded projects and envs.
class ProjectFilter
  Row = Struct.new(:project, :matched_env_ids)

  def initialize(projects, query)
    @projects = projects
    @terms = query.to_s.downcase.split
  end

  def call
    @projects.filter_map do |project|
      matched_env_ids = []
      found = @terms.all? do |term|
        envs = project.project_envs.select { |env| env.name.include?(term) }
        matched_env_ids.concat(envs.map(&:id))
        project.name.downcase.include?(term) || project.key.include?(term) || envs.any?
      end
      Row.new(project, matched_env_ids.uniq) if found
    end
  end
end
