# R8: a PR-mode connection's changes, collected (docs/requirements/R8).
# index/show read; preview renders from the latest git without pushing;
# submit is the one way a PR-mode change leaves Kongsole (a person, never an
# agent -- Q13); pr_url records the PR the person opened on the git host;
# abandon drops an open changeset. Only the current connection's changesets.
class ChangesetsController < ApplicationController
  include Reauthentication

  before_action :require_session!
  before_action :set_changeset, except: :index

  def index
    @changesets = Changeset.where(kong_connection: current_connection)
      .order(Arel.sql("CASE status WHEN 'open' THEN 0 ELSE 1 END"), created_at: :desc)
  end

  def show
    @items = @changeset.items
  end

  def preview
    @items = @changeset.items
    @preview = Kong::ChangesetRenderer.new(changeset: @changeset, secret: current_secret).preview
  end

  def submit
    unless env_name_confirmed?
      return redirect_to(changeset_path(@changeset), alert: "Connection name didn't match -- nothing was submitted.")
    end
    if requires_reauth? && !reauthenticated?
      return redirect_to(changeset_path(@changeset), alert: "Password confirmation failed -- nothing was submitted.")
    end

    Kong::ChangesetSubmitter.new(
      changeset: @changeset, client: current_client, secret: current_secret,
      actor_username: current_connection.auth_username, actor_operator: current_operator,
      acknowledge_drift: params[:acknowledge_drift] == "1", env_acknowledged: params[:acknowledge_env_vars] == "1",
      delete_confirmations: typed_delete_names
    ).call

    redirect_to changeset_path(@changeset), notice: "Branch #{@changeset.branch} pushed. Open the pull request on your git host."
  rescue Kong::ChangeGuardrails::Violation, NotImplementedError => e
    redirect_to changeset_path(@changeset), alert: e.message
  rescue Kong::GitClient::Error, Kong::DeckCli::Error, Kong::Client::Error => e
    flash[:error_explanation] = explain_error(e).to_flash if Kong::ChangesetRenderer.explainable?(e)
    redirect_to changeset_path(@changeset), alert: Kong::ChangesetRenderer.scrub(e.message)
  end

  def pr_url
    url = params[:pr_url].to_s.strip
    if acceptable_pr_url?(url)
      @changeset.update!(pr_url: url)
      redirect_to changeset_path(@changeset), notice: "Pull request recorded."
    else
      redirect_to changeset_path(@changeset), alert: pr_url_refusal
    end
  end

  def abandon
    abandoned = @changeset.with_lock do
      next false unless @changeset.open?

      @changeset.items.update_all(status: "cancelled", updated_at: Time.current)
      @changeset.update!(status: "abandoned")
    end
    unless abandoned
      return redirect_to(changeset_path(@changeset), alert: "This changeset is #{@changeset.status}; only an open one can be abandoned.")
    end

    redirect_to changesets_path, notice: "Changeset ##{@changeset.id} abandoned. Nothing was pushed."
  end

  private

  # {plan id => the name typed for it}, only compared against each delete's name.
  def typed_delete_names
    raw = params[:confirm_delete]
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.transform_values(&:to_s) : {}
  end

  def set_changeset
    @changeset = Changeset.find_by!(id: params[:id], kong_connection: current_connection)
  end

  # Only a web link, and on the project's own git host when one is set: the
  # URL becomes a link on this page for everyone who opens it.
  def acceptable_pr_url?(url)
    uri = URI.parse(url)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?

    host = git_web_host
    host.nil? || uri.host.casecmp?(host)
  rescue URI::InvalidURIError
    false
  end

  # The project's own setting: a connection's copy is refreshed only on its save.
  def git_web_host
    template = current_connection.project&.git_web_url.presence || current_connection.git_web_url.presence
    template && URI.parse(template.gsub("{branch}", "branch")).host
  rescue URI::InvalidURIError
    nil
  end

  def pr_url_refusal
    host = git_web_host
    host ? "That is not a pull request on #{host} -- paste the link from the project's git host." : "Paste an http(s) link to the pull request."
  end
end
