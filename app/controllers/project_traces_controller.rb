# R5.6: the request tracer -- no login, no call to Kong: it reads what this
# machine last synced, so it works off the project's network too.
class ProjectTracesController < ApplicationController
  def show
    @project = Project.find_by!(key: params[:key])
    @trace_envs = ProjectOverview.new(@project).rows
    @trace_form = TraceForm.new(project: @project, env: params[:env] || default_env, http_method: params[:method] || "GET",
      host: params[:host], path: params[:path])
    return unless params[:path] || params[:host]

    if @trace_form.valid?
      @trace = Kong::RequestTrace.call(connection: @trace_form.connection, http_method: @trace_form.http_method,
        host: @trace_form.host, path: @trace_form.path_only, query: @trace_form.query)
    else
      @trace_errors = @trace_form.errors
      render :show, status: :unprocessable_entity
    end
  end

  private

  def default_env
    @trace_envs.find(&:synced_at)&.env&.name
  end
end
