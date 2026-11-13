require_relative "language"

# The rule keys of the eval cases (evals/README.md, Expectation keys), each
# checked against what the visitor got from the case's last message: the
# reply as the visitor reads it, with the demo notice the system put before a
# conversation's first reply and any fixed line after it; the tools the model
# called in that turn, with their arguments; and what the attempt left in the
# visitor's rows. The rubric is the judge's (Evals::Judge).
module Evals
  # A check's outcome: :pass, :fail, or :skip for a key whose feature arrives
  # at a later milestone, never reported as passed.
  Check = Data.define(:key, :status, :detail) do
    def passed? = status == :pass
    def failed? = status == :fail
  end

  # A tool call of a turn, as its span recorded it (FR-12): the arguments as
  # the trace kept them, nil when they could not be read back whole; the
  # result's text, cut as the trace cuts it; a refusal's reason code; whether
  # the tool failed.
  ToolCall = Data.define(:name, :input, :output, :refusal, :failed) do
    def initialize(name:, input:, output: nil, refusal: nil, failed: false) = super
  end

  # What the case's last message got. reply is what the visitor reads, notice
  # included when the system put one first; tool_calls are the turn's, in the
  # order they ran.
  Observation = Data.define(:reply, :notice, :tool_calls, :reservation_created, :conversation_reset, :data_deleted) do
    # The reply without the notice: what the attendant and the fixed lines wrote.
    def body = notice ? reply.delete_prefix(notice).delete_prefix("\n\n") : reply
  end

  # The values the fact key names in config/store.yml (README, fact): a
  # key, or a key with the entry it selects.
  module Facts
    READERS = {
      "saturday_hours" => ->(sheet, _) { sheet.week.to_h.fetch("saturday")&.closes },
      "delivery_areas" => ->(sheet, area) { sheet.topic("delivery").fetch("areas").find { |entry| entry["name"] == area }&.fetch("fee") }
    }.freeze
    SELECTED = %w[delivery_areas].freeze

    # The value, or nil when the sheet has none: a selector naming no entry,
    # a closed Saturday.
    def self.value(fact, sheet = StoreSheet.current)
      key, selector = fact.is_a?(Hash) ? fact.first : [ fact, nil ]
      READERS.fetch(key).call(sheet, selector)
    end

    def self.known?(fact)
      key, selector = fact.is_a?(Hash) && fact.size == 1 ? fact.first : [ fact, nil ]
      READERS.key?(key) && (SELECTED.include?(key) ? selector.is_a?(String) : selector.nil?)
    end
  end

  class Checks
    # Keys whose feature has not arrived; the README lists them for the cases
    # that will need them.
    LATER = { "booking_created" => "FR-08 bookings arrive at M2", "guardrail_replaced" => "the FR-20 guardrail arrives at M2" }.freeze

    def initialize(phrases:, sheet: StoreSheet.current)
      @phrases = phrases
      @sheet = sheet
    end

    def run(kase, observation)
      (kase.expect.keys - [ "rubric" ]).map do |key|
        next Check.new(key:, status: :skip, detail: LATER.fetch(key)) if LATER.key?(key)

        passed, detail = send(:"check_#{key}", kase.expect.fetch(key), observation, kase)
        Check.new(key:, status: passed ? :pass : :fail, detail:)
      end
    end

    private

    # FR-02: the reply's own words, and a notice, when there is one, in the
    # same language: the system writes it in the language the reply's tag named.
    def check_language(expected, observation, _kase)
      detection = Language.detect(observation.body)
      scores = detection.scores.map { |language, score| "#{language} #{score}" }.join(", ")
      notice = notice_language(observation.notice)
      return [ false, "the notice is in #{notice || "no known language"}, the reply in #{detection.language}" ] if observation.notice && notice != expected

      [ detection.language == expected, "#{detection.language || "undecided"} (#{scores})" ]
    end

    def notice_language(notice)
      AgentRunner::LANGUAGES.find { |_, locale| FixedReply.notice(locale) == notice }&.first
    end

    def check_tools(expected, observation, _kase)
      names = observation.tool_calls.map(&:name)
      [ names == expected, "called #{names.inspect}" ]
    end

    # Each tool's constraints hold for at least one of its calls in the turn.
    def check_tool_args(expected, observation, _kase)
      misses = expected.reject do |tool, constraints|
        observation.tool_calls.any? { |call| call.name == tool && call.input && constraints.all? { |key, value| meets?(call.input, key, value) } }
      end
      seen = observation.tool_calls.map { |call| "#{call.name}(#{call.input ? call.input.to_json : "unreadable"})" }
      [ misses.empty?, misses.empty? ? seen.join(", ") : "no call met #{misses.to_json}; calls: #{seen.join(", ").presence || "none"}" ]
    end

    def meets?(input, key, value)
      if key.end_with?("_includes")
        fold(input[key.delete_suffix("_includes")].to_s).include?(fold(value.to_s))
      else
        input[key] == value
      end
    end

    def check_must_include_any(phrases, observation, _kase)
      found = present(phrases, observation.reply)
      [ found.any?, found.any? ? "found #{found.inspect}" : "none of #{phrases.inspect}" ]
    end

    def check_must_include_all(phrases, observation, _kase)
      missing = phrases - present(phrases, observation.reply)
      [ missing.empty?, missing.empty? ? "found all" : "missing #{missing.inspect}" ]
    end

    def check_must_not_include(phrases, observation, _kase)
      found = present(phrases, observation.reply)
      [ found.empty?, found.empty? ? "none found" : "found #{found.inspect}" ]
    end

    def check_max_chars(limit, observation, _kase)
      length = observation.body.length
      [ length <= limit, "#{length} characters" ]
    end

    # README, handoff_offered: a phrase of phrases.yml in the reply's language.
    def check_handoff_offered(expected, observation, kase)
      found = present(@phrases.fetch("handoff_offer").fetch(kase.reply_language), observation.reply)
      [ found.any? == expected, found.any? ? "offered: #{found.inspect}" : "no handoff phrase" ]
    end

    def check_fact(fact, observation, _kase)
      value = Facts.value(fact, @sheet)
      [ observation.reply.include?(value), "#{value.inspect} #{observation.reply.include?(value) ? "found" : "missing"}" ]
    end

    def check_reservation_created(expected, observation, _kase) = flag(expected, observation.reservation_created)
    def check_conversation_reset(expected, observation, _kase) = flag(expected, observation.conversation_reset)
    def check_data_deleted(expected, observation, _kase) = flag(expected, observation.data_deleted)

    def flag(expected, actual) = [ actual == expected, actual.to_s ]

    def present(phrases, text)
      folded = fold(text)
      phrases.select { |phrase| folded.include?(fold(phrase)) }
    end

    # Case-insensitive, as the README asks; accents count.
    def fold(text) = text.unicode_normalize(:nfc).downcase
  end
end
