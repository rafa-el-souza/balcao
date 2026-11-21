# The Telegram delivery watch's look (Telegram::Watch), every ten minutes,
# five after the canary (config/recurring.yml). Never tried again: the next
# look is ten minutes away. A look that cannot even start is a line and a
# failure told to the watch's heartbeat.
class TelegramWatchJob < ApplicationJob
  queue_as :default

  def perform
    Telegram::Watch.new.call
  rescue StandardError => e
    Rails.logger.error("telegram watch: not looked, #{e.class}\n#{Canary.frames(e)}")
    Heartbeat.telegram.failure("telegram: not looked, #{e.class}")
  end
end
