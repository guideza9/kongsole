# R3: the "hide detailed hints" switch. No user database (docs/DESIGN.md
# section 3), so the choice belongs to the browser, as a cookie the server
# reads -- the page renders in the chosen mode with no flash of hints.
class HintPreferencesController < ApplicationController
  MODES = %w[detailed compact].freeze

  def update
    mode = params[:mode].to_s
    return head(:unprocessable_entity) unless MODES.include?(mode)

    cookies.permanent[:kongsole_hints] = { value: mode, same_site: :lax }
    redirect_back fallback_location: root_path
  end
end
