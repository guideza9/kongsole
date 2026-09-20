# A dashboard of every connection's last known status -- distinct from
# `/up`, which only answers "is the Rails process alive". This answers "is
# each Kong connection reachable, and what did we last learn about it"
# (docs/DESIGN.md section 14).
class HealthController < ApplicationController
  def show
    @connections = KongConnection.order(:rank, :name)
  end
end
