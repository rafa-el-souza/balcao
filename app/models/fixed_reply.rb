# The texts the system writes instead of the model (NFR-09): the demo notice
# before a conversation's first reply (FR-01), the commands' confirmations
# (FR-04, FR-05, FR-12), the fallback of a turn the model could not answer
# (NFR-03), the reply to a refusal (SR-19) and the fixed line of each
# reservation a turn stored (NFR-02). They live in config/locales, in the
# conversation's language.
module FixedReply
  module_function

  def notice(locale) = I18n.t("turn.notice", locale:)

  def with_notice(text, locale) = "#{notice(locale)}\n\n#{text}"

  # The reply as the model wrote it, for the history it reads back
  # (AgentRunner::History): the prompt tells it the system adds the notice,
  # so its own past reply never shows one.
  def without_notice(body)
    I18n.available_locales.each do |locale|
      prefix = "#{notice(locale)}\n\n"
      return body.delete_prefix(prefix) if body.start_with?(prefix)
    end
    body
  end

  def fallback(locale) = I18n.t("turn.fallback", locale:)

  def declined(locale) = I18n.t("turn.declined", locale:)

  def command(name, locale, **) = I18n.t("commands.#{name}", locale:, **)

  def reservations(reservations, locale)
    reservations.map do |reservation|
      pickup = I18n.l(reservation.pickup_until.in_time_zone, format: I18n.t("turn.pickup_format", locale:), locale:)
      I18n.t("turn.reservation", locale:, code: reservation.code, quantity: reservation.quantity,
                                 product: reservation.product.name, pickup_until: pickup)
    end.join("\n")
  end

  def with_reservations(text, reservations, locale)
    return text if reservations.empty?

    "#{text}\n\n#{self.reservations(reservations, locale)}"
  end
end
