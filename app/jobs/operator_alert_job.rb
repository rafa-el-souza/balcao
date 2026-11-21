# Sends one of the operator's alerts through the bot (OperatorAlert, threat
# model SR-35): enqueued once the alert's row is committed, again by the alert
# itself for its next attempt's time, and by NFR-03's sweep for one left
# pending. Its argument is the alert's row, never the chat or the text. The
# alert's claim and its three attempts decide, so the job has no retry of its
# own: what breaks it leaves the row claimed for the sweep.
class OperatorAlertJob < ApplicationJob
  queue_as :default

  def perform(alert_id) = OperatorAlert.find_by(id: alert_id)&.deliver
end
