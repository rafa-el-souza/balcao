namespace :telegram do
  # FR-19: run in a new container of the application's image (the runbook,
  # which never uses --reuse: SR-24, pull request #65):
  # kamal app exec -d ensaio --roles=web "bin/rails telegram:setup"
  desc "Sets the Telegram bot from the repository: its webhook, command menu and profile; prints getWebhookInfo (FR-19)"
  # Each failure with its own remedy (the hunter's H4 on pull request #41): a
  # write Telegram refused is written by a run after the wait it named; a
  # field of the webhook that differs comes back the same at every run.
  task setup: :environment do
    result = Telegram::Setup.new.call
    problems = []
    problems << "not written: #{result.failed.join(", ")}; run it again after the wait Telegram named (the runbook)" if result.failed.any?
    if result.differs.any?
      problems << "the webhook Telegram reports differs in #{result.differs.join(", ")}, which a run again sets the same way; " \
                  "check the values against the runbook's part on the bot before running it again"
    end
    abort("telegram:setup: #{problems.join("; ")}") if problems.any?
  end
end
