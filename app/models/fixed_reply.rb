# The texts the system writes instead of the model (NFR-09): the demo notice
# before a conversation's first reply (FR-01), the commands' confirmations
# (FR-04, FR-05, FR-12), the fallback of a turn the model could not answer
# (NFR-03), FR-09's decline, the reply to a refusal (SR-19), the offer of the
# pharmacist (FR-10's MVP note), the emergency line (FR-09), the replies of a
# month paused at its budget cap and of a pause the operator forced (FR-14)
# and the fixed line of each
# reservation a turn stored (NFR-02). They live in config/locales, in the
# conversation's language.
module FixedReply
  module_function

  def notice(locale) = I18n.t("turn.notice", locale:)

  def with_notice(text, locale) = "#{notice(locale)}\n\n#{text}"

  def fallback(locale) = I18n.t("fallback.model_error", locale:)

  # FR-14: a month that reached its cap answers every message with this, and
  # no model is called (SR-02).
  def paused(locale) = I18n.t("budget.paused", locale:)

  # FR-14: a pause the operator forced answers with a text of its own, which
  # names no limit and no date, since the month's cap is not what paused it
  # (the owner, 2026-11-15).
  def forced_pause(locale) = I18n.t("budget.forced", locale:)

  # FR-09's decline, one or two sentences naming the store's pharmacist: the
  # reply to a refusal (SR-19) and, from M2, to a reply the guardrail replaces
  # (FR-20). The turn puts the offer after it (TurnProcessor).
  def declined(locale) = I18n.t("turn.declined", locale:)

  # FR-10's MVP note: until M2 the offer of the pharmacist is this line, with
  # the pharmacy's phone and the counter's hours from the store sheet, so an
  # edit of config/store.yml changes it with no code change (FR-26). Days in
  # a row with the same hours go together, and a closed day is left out.
  def offer(locale, sheet = StoreSheet.current)
    runs = sheet.week.chunk_while { |(_, before), (_, after)| before == after }.select { |run| run.first.last }
    I18n.t("turn.offer.line", locale:, phone: sheet.topic("contact").fetch("phone"),
                              hours: runs.map { |run| opening(run, locale) }.join("; "))
  end

  # A text with nothing of its own (a reply that was its tag alone) is the
  # line alone.
  def with_offer(text, locale, sheet = StoreSheet.current) = paragraphs(text, offer(locale, sheet))

  # FR-09: a message that may be an emergency ends with the public emergency
  # numbers, real on purpose (the owner's decision of 2026-11-14).
  def emergency(locale) = I18n.t("turn.emergency", locale:)

  def with_emergency(text, locale) = paragraphs(text, emergency(locale))

  def paragraphs(*texts) = texts.reject(&:blank?).join("\n\n")
  private_class_method :paragraphs

  # One run of days with the same hours, "de segunda a sexta, das 08:00 às
  # 20:00" or "aos sábados, das 08:00 às 14:00".
  def opening(run, locale)
    (first, hours), (last, _) = run.first, run.last
    days = I18n.t("turn.offer.on_day.#{first}", locale:) if run.one?
    days ||= I18n.t("turn.offer.days", locale:, first: I18n.t("turn.offer.day.#{first}", locale:),
                                       last: I18n.t("turn.offer.day.#{last}", locale:))
    I18n.t("turn.offer.hours", locale:, days:, opens: hours.opens, closes: hours.closes)
  end
  private_class_method :opening

  def command(name, locale, **) = I18n.t("commands.#{name}", locale:, store: store_name, **)

  # FR-19, FR-18: the greeting of /start and of an agreement, and /help's list.
  def greeting(locale) = command(:start, locale)

  def help(locale) = command(:help, locale, privacy: privacy_url)

  # FR-19, agreement first: FR-01's notice, what happens to a message and the
  # phrase of the button that agrees, in the language of the person's app.
  def ask(locale)
    with_notice(I18n.t("telegram.ask", locale:, privacy: privacy_url,
                                       agree: CommandPhrases.current.agreement(AgentRunner::LANGUAGES.key(locale.to_s))), locale)
  end

  # FR-05 on Telegram: the deletion's confirmation, then what the command does
  # not reach, the copy of the chat in the visitor's own app (FR-19, /privacy).
  def telegram_deleted(locale) = "#{command(:delete, locale)}\n\n#{I18n.t("telegram.own_copy", locale:)}"

  # FR-19: a message that is not text, and a text over 1,000 characters.
  def not_text(locale) = I18n.t("telegram.not_text", locale:)

  def too_long(locale) = I18n.t("telegram.too_long", locale:)

  def privacy_url = "#{Rails.configuration.x.public_origin}/privacy"

  def store_name(sheet = StoreSheet.current) = sheet.identity.fetch("name")

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
