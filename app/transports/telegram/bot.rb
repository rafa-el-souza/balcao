module Telegram
  # The demo's bot (FR-19, ADR-0016, ADR-0017): what the repository fixes about
  # it. BotFather keeps its creation, its token, its privacy policy, its photo
  # and the switch that keeps it out of groups (design §9.2, the runbook).
  module Bot
    # Public and permanent (the owner's choice of 2026-11-14). A command typed
    # with it ("/help@BalcaoDemoBot") is that command (CommandPhrases).
    USERNAME = "BalcaoDemoBot".freeze
    # Where Telegram posts the updates (design §6.6).
    WEBHOOK_PATH = "/webhooks/telegram".freeze
    # The one kind of update the bot asks for (ADR-0017, threat model SR-42);
    # the job drops any other all the same, since the list is kept on
    # Telegram's side.
    ALLOWED_UPDATES = %w[message].freeze
    # Few connections at a time to the one web process (SR-09): Telegram's
    # default is 40, and Puma runs 3 threads.
    MAX_CONNECTIONS = 3
  end
end
