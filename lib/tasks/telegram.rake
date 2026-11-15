namespace :telegram do
  # FR-19: run inside the application's container (the runbook):
  # kamal app exec -d ensaio --roles=web --reuse "bin/rails telegram:setup"
  desc "Sets the Telegram bot from the repository: its webhook, command menu and profile; prints getWebhookInfo (FR-19)"
  task setup: :environment do
    result = Telegram::Setup.new.call
    problems = []
    problems << "not written: #{result.failed.join(", ")}" if result.failed.any?
    problems << "the webhook Telegram reports differs in #{result.differs.join(", ")}" if result.differs.any?
    abort("telegram:setup: #{problems.join("; ")}; run it again later (the runbook)") if problems.any?
  end
end
