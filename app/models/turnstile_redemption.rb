# A Turnstile token that minted a web visitor, by its SHA-256, for five
# minutes and the nightly job's seven days: its key refuses the same token a
# second time (threat model SR-39; Turnstile#passed?).
class TurnstileRedemption < ApplicationRecord
  self.primary_key = "digest"
end
