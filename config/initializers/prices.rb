# FR-14: the budget ledger charges every model call at the price table's
# prices (app/models/prices.rb). Production reads the table at boot, so a bad
# table stops the boot, as a blank secret does (threat model SR-25), instead
# of failing after the first model call of a turn was paid and leaving it,
# and every later one, uncharged (review findings C2 and S7 of pull request
# #29). Elsewhere the specs read it, and CI fails on a bad one.
Rails.application.config.after_initialize { Prices.table } if Rails.env.production?
