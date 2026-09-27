# R7: export what the logged-in connection's Kong holds under some select
# tags, as decK YAML -- previewed first, downloaded on request. The dump is
# read with this session's credential and passes Kong::ExportSanitizer
# before anything is shown; the download is audited by digest only.
class ExportsController < ApplicationController
  before_action :require_session!

  def new
    @select_tags = Array(current_connection.select_tags)
    @select_tags_default = @select_tags
  end

  def preview
    @select_tags = requested_tags
    @result = run_export(record: false)
    render :preview unless performed?
  end

  def create
    @select_tags = requested_tags
    result = run_export(record: true)
    return if performed?

    send_data result.yaml, filename: filename, type: "application/yaml", disposition: "attachment"
  end

  private

  # The download carries the preview's digest (preview_sha256): if Kong moved
  # in between, the new file is shown for review instead of sent.
  def run_export(record:)
    Kong::ConfigExport.call(
      connection: current_connection, secret: current_secret, select_tags: @select_tags,
      actor_username: current_connection.auth_username, actor_operator: current_operator, record: record,
      expected_sha256: record ? previewed_sha256 : nil
    )
  rescue Kong::ConfigExport::Changed => e
    @result = e.result
    flash.now[:alert] = "Kong changed since your preview, so nothing was downloaded. This is the file as it is now: review it, then download again."
    render :preview, status: :conflict
    nil
  rescue Kong::ExportSanitizer::Refused => e
    @export_errors = { select_tags: [ e.message ] }
    render_form(:unprocessable_entity)
  rescue Kong::DeckCli::Error, Kong::Client::Error, Faraday::Error => e
    flash.now[:alert] = "Couldn't export from #{current_connection.name}: #{Kong::CertificateKeyPolicy.scrub(e.message)}"
    flash.now[:error_explanation] = explain_error(e).to_flash
    render_form(:bad_gateway)
  rescue Kong::DeckDocument::Unparseable => e
    flash.now[:alert] = "Couldn't read what decK dumped: #{e.message}"
    render_form(:bad_gateway)
  end

  def render_form(status)
    @select_tags_default = Array(current_connection.select_tags)
    render :new, status: status
    nil
  end

  def previewed_sha256
    digest = params[:preview_sha256]
    digest.is_a?(String) && digest.match?(/\A\h{64}\z/) ? digest : nil
  end

  # One field, comma- or space-separated, in the order typed. Anything but a
  # String is read as no tags, which the sanitizer then refuses.
  def requested_tags
    raw = params[:select_tags]
    raw.is_a?(String) ? raw.split(/[\s,]+/).reject(&:blank?) : []
  end

  # <project>-<env>-<tags joined by +>-<YYYYMMDD-HHMM>.yaml: the time lives
  # here, never in the file, so two exports of the same Kong are identical.
  def filename
    scope = (current_connection.qualified_name || current_connection.name).tr("/", "-")
    "#{scope}-#{@select_tags.join('+')}-#{Time.current.strftime('%Y%m%d-%H%M')}.yaml"
  end
end
