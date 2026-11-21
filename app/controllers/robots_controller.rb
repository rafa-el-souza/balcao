# robots.txt (#22's sister of C1 and #40's thirteenth line, settled in
# M3-6b). A route's answer rather than a file of public/, whose year of cache
# suits only names that carry a digest: a crawler keeps robots.txt for up to
# 24 hours (RFC 9309, 2.4), and Google may keep it longer on a longer max-age,
# so a changed file reaches crawlers within a day.
#
# Every page may be crawled, on the demo and on a rehearsal host alike (one
# image serves both): a rehearsal host says noindex on every answer instead
# (design §8, X-Robots-Tag), which a crawler reads only on a page robots.txt
# lets it fetch. Disallowing a page would keep it in search results, with no
# text, whenever another page links to it.
class RobotsController < ApplicationController
  BODY = <<~TEXT.freeze
    # Every page may be crawled. A rehearsal host says noindex on each answer
    # instead (X-Robots-Tag), which a crawler reads only where it may fetch.
    User-agent: *
    Allow: /
  TEXT

  def show
    expires_in 1.day, public: true
    render plain: BODY
  end
end
