module ApplicationCable
  # The cable reads the visitor cookie the API set (design FR-18, threat model
  # SR-03), and knows the source address its subscriptions count against
  # (SR-01, SR-11). A page without the cookie may still follow a trace by its
  # token (FR-12), so the connection is open to it, with no visitor.
  class Connection < ActionCable::Connection::Base
    identified_by :identity_hash, :source

    def connect
      self.identity_hash = WebSession.identity_hash_of(cookies)
      self.source = EdgeLimits.source(request.env)
    end
  end
end
