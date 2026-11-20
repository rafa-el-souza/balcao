# ADR-0003's gate (FR-14): the economy model serves only on the full eval
# run's word, the committed evals/economy_allowed.yml. Every process reads it
# once, at boot (Budget.read_economy_allowed), so what may serve changes with
# a deploy, and a file that is not the gate the run writes is said once, in a
# warning line, rather than in a turn or a request (review finding S6 of pull
# request #29). The suite closes the gate before each example
# (spec/support/economy_gate.rb).
Rails.application.config.after_initialize { Rails.configuration.x.economy_allowed = Budget.read_economy_allowed }
