require_relative "../../config/required_environment"

# A production environment the boot check accepts (config/required_environment.rb):
# every required name with a value, and the ones whose shape it checks in that
# shape, the monitor URLs the public name requires among them. A spec that boots production merges its own values on top.
module ProductionEnv
  module_function

  def complete
    Balcao::RequiredEnvironment::NAMES.to_h { |name| [ name, "value-of-#{name.downcase}" ] }.merge(
      "MODEL_ADAPTER" => "real", "BUDGET_CAP_USD" => "10",
      "TELEGRAM_BOT_TOKEN" => "123456789:AAvalue-of_the-bot-token-for-the-specs", "TELEGRAM_WEBHOOK_SECRET" => "value-of_the-webhook-secret",
      "MONITOR_URL" => "https://monitor.example/api/v1/heartbeat/canary-of-the-specs",
      "TELEGRAM_MONITOR_URL" => "https://monitor.example/api/v1/heartbeat/telegram-of-the-specs"
    )
  end
end
