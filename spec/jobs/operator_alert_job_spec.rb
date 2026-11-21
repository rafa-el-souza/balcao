require "rails_helper"

# The operator's alert job (threat model SR-35, NFR-03): its argument is the
# alert's row, never the chat or the text.
RSpec.describe "SR-35 NFR-03 OperatorAlertJob" do
  # Review finding H13 of pull request #63 (teorico; fixed, since the job is
  # this pull request's own): a job whose alert is gone did nothing, with no
  # line.
  it "says so when its alert is gone, naming only the row's id" do
    allow(Rails.logger).to receive(:error)
    id = SecureRandom.uuid_v7

    OperatorAlertJob.perform_now(id)

    expect(Rails.logger).to have_received(:error).with("operator alert #{id}: gone, nothing to send")
  end
end
