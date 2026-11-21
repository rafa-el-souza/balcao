# Line coverage of the whole RSpec run (design NFR-08), measured in CI, where
# the RSpec step sets COVERAGE=1 (spec/spec_helper.rb starts SimpleCov only
# then, so a single spec file run by hand is never held to the threshold).
#
# The threshold is the ratchet of NFR-08: set at M3's CI furniture to the
# measured value minus three points, never to a round number, and only ever
# raised. CI's log prints each run's figure ("Line coverage: ..."); the pull
# request whose run measures four points or more above the threshold raises
# it to that figure minus three.
#
# Measured on 2026-11-21 (M3-5): 97.86 % of the lines, 4,119 of 4,209.
SimpleCov.start "rails" do
  coverage :line do
    minimum 94.86
  end
end
