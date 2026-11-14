namespace :telegram do
  # FR-19: run inside the application's container (the runbook):
  # kamal app exec -d ensaio --reuse "bin/rails telegram:setup"
  desc "Registers the Telegram bot's webhook and prints getWebhookInfo (FR-19)"
  task setup: :environment do
    Telegram::Setup.new.call
  end
end
