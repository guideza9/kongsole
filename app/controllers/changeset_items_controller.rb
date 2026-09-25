# R8: takes one item out of an open changeset before it is submitted. The
# plan is kept, cancelled, so what was proposed stays on record.
class ChangesetItemsController < ApplicationController
  before_action :require_session!

  def destroy
    changeset = Changeset.find_by!(id: params[:changeset_id], kong_connection: current_connection)
    item = changeset.items.find(params[:id])

    # Locked with the same row a submit holds: an item never leaves a changeset
    # that is being pushed.
    removed = changeset.with_lock { changeset.open? && item.update!(status: "cancelled") }
    unless removed
      return redirect_to(changeset_path(changeset), alert: "This changeset is #{changeset.status}; its items can no longer change.")
    end

    redirect_to changeset_path(changeset), notice: "Removed #{item.operation} #{item.entity_type} #{item.entity_label} from the changeset."
  end
end
