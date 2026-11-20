# A Turnstile token that minted a web visitor, by its SHA-256, kept for the
# nightly job's seven days though a token lives five minutes: its unique
# index refuses the same token a second time (threat model SR-39;
# Turnstile#passed?).
class TurnstileRedemption < ApplicationRecord
end
