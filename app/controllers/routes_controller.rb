# R2: "Add route" -- a form (RouteForm) opened under one service. The
# service is a live one from the read-model, or (PR mode) one still waiting
# as a create in the open changeset, named by its provisional id; the route
# joins the same changeset and decK nests it under that service.
#
# #overlap answers the form's live check (Kong::RouteOverlap) from the
# read-model and the open changeset -- never Kong.
class RoutesController < ApplicationController
  include ProposesFromForm

  before_action :require_session!
  before_action -> { require_writable!(back_to: entities_path(type: "service")) }, except: :overlap
  before_action :set_service, except: :overlap

  def new
    @form = RouteForm.new
  end

  def create
    @form = RouteForm.new(route_params)
    return render(:new, status: :unprocessable_entity) unless @form.valid?

    propose_from_form(entity_type: "route", parent_kong_id: @service_kong_id,
      attributes: @form.to_attributes(select_tags: current_connection.select_tags, service_kong_id: @service_kong_id))
  end

  def overlap
    overlaps = Kong::RouteOverlap.check(connection: current_connection, changeset: current_open_changeset,
      hosts: list_param(:hosts), paths: list_param(:paths), methods: list_param(:methods))
    render json: { overlaps: overlaps }
  end

  private

  def set_service
    @service_kong_id = params[:service_id].to_s
    @service_label = service_name(@service_kong_id)
    return if @service_label

    redirect_to entities_path(type: "service"), alert: "That service isn't on #{current_connection.name} -- pick one from the list."
  end

  def service_name(kong_id)
    return nil if kong_id.blank?

    live = KongEntity.active.find_by(kong_connection: current_connection, entity_type: "service", kong_id: kong_id)
    return live.name if live

    current_open_changeset&.items&.find_by(entity_type: "service", operation: "create", provisional_kong_id: kong_id)&.after&.dig("name")
  end

  def route_params
    params.require(:route_form).permit(:name, :hosts, :paths, :strip_path, :preserve_host, :tags, protocols: [], methods: [])
  end

  def list_param(key)
    Array(params[key]).map(&:to_s)
  end
end
