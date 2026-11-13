require_relative "checks"

# The eval cases, evals/cases.yaml (evals/README.md, Case format), read and
# checked before any of them runs. A field or an expectation key the runner
# does not know, a suite, language or milestone outside the README's lists, a
# seed with no overlay, turns that do not alternate from a visitor message to
# the message under test, an expectation of the wrong type, a fact the store
# sheet cannot give, and a boundary or injection case judged by a rubric alone
# (README, Flakiness policy) are refused with the case's id, so a typo never
# becomes a check that silently passes.
module Evals
  SUITES = %w[greeting language store catalogue reservation booking boundary handoff injection memory].freeze
  LANGUAGES = %w[pt en es].freeze
  MILESTONES = %w[MVP M2 M3 M4 M5].freeze
  # The milestones whose cases --all and --suite run: those whose tools and
  # requirements exist (design §9). Closing a milestone adds its name.
  RUNNABLE_MILESTONES = %w[MVP].freeze
  # The suites a rubric alone may not judge (README, Flakiness policy).
  RULED_SUITES = %w[boundary injection].freeze

  # One case. messages are the visitor's, in order, the last one the message
  # under test; the replies between them are the attendant's, run live.
  Case = Data.define(:id, :suite, :lang, :milestone, :seed, :fast, :messages, :expect) do
    def rubric = expect["rubric"]
    def runnable? = RUNNABLE_MILESTONES.include?(milestone)
    # The language the reply should be in: the expectation's, else the message's.
    def reply_language = expect.fetch("language", lang)
  end

  class CaseSet
    PATH = Rails.root.join("evals/cases.yaml")
    SEEDS = Rails.root.join("evals/seeds")
    FIELDS = %w[id suite lang milestone seed fast turns expect].freeze
    ID = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    ANY = "(any)".freeze

    BOOLEAN = ->(value) { [ true, false ].include?(value) }
    PHRASES = ->(value) { value.is_a?(Array) && value.any? && value.all? { |phrase| phrase.is_a?(String) && phrase.strip.present? } }
    # Each expectation key and the values it takes (README, Expectation keys).
    KEYS = {
      "language" => ->(value) { LANGUAGES.include?(value) },
      "tools" => ->(value) { value.is_a?(Array) && value.all? { |name| name.is_a?(String) && name.present? } },
      "tool_args" => ->(value) { value.is_a?(Hash) && value.values.all? { |constraints| constraints.is_a?(Hash) && constraints.any? } },
      "must_include_any" => PHRASES, "must_include_all" => PHRASES, "must_not_include" => PHRASES,
      "max_chars" => ->(value) { value.is_a?(Integer) && value.positive? },
      "handoff_offered" => BOOLEAN,
      "fact" => ->(value) { Facts.known?(value) && Facts.value(value).present? },
      "reservation_created" => BOOLEAN, "booking_created" => BOOLEAN, "conversation_reset" => BOOLEAN,
      "data_deleted" => BOOLEAN, "guardrail_replaced" => BOOLEAN,
      "rubric" => ->(value) { value.is_a?(String) && value.strip.present? }
    }.freeze

    class Invalid < StandardError; end

    def self.load(path = PATH, seeds: SEEDS)
      data = YAML.safe_load_file(path)
      raise Invalid, "#{path} must hold a list of cases" unless data.is_a?(Array)

      new(data.map { |entry| build(entry, seeds) })
    rescue Psych::Exception => e
      raise Invalid, "#{path}: #{e.message}"
    end

    def self.build(entry, seeds)
      raise Invalid, "every case must be a mapping with an id" unless entry.is_a?(Hash) && entry["id"].is_a?(String)

      id = entry["id"]
      fail_case = ->(message) { raise Invalid, "#{id}: #{message}" }
      fail_case.call("the id must be a lowercase slug") unless id.match?(ID)
      unknown = entry.keys - FIELDS
      fail_case.call("unknown field #{unknown.join(", ")}") if unknown.any?
      { "suite" => SUITES, "lang" => LANGUAGES, "milestone" => MILESTONES }.each do |field, allowed|
        fail_case.call("#{field} must be one of #{allowed.join(", ")}, got #{entry[field].inspect}") unless allowed.include?(entry[field])
      end
      seed = entry.fetch("seed", "default")
      fail_case.call("seed #{seed.inspect} has no overlay in evals/seeds") unless seed == "default" || (seed.is_a?(String) && seeds.join("#{seed}.yml").file?)
      fail_case.call("fast must be true or false") unless [ nil, true, false ].include?(entry["fast"])

      Case.new(id:, suite: entry["suite"], lang: entry["lang"], milestone: entry["milestone"], seed:, fast: entry["fast"] == true,
               messages: messages(entry["turns"], fail_case), expect: expectations(entry["expect"], entry["suite"], fail_case))
    end
    private_class_method :build

    # The visitor's messages, from turns that alternate from a visitor message
    # to the message under test, each reply between them "(any)": the runner
    # runs it live, so a scripted one would never be checked.
    def self.messages(turns, fail_case)
      fail_case.call("turns must be a non-empty list") unless turns.is_a?(Array) && turns.any?
      roles = turns.map do |turn|
        fail_case.call("each turn must be { user: text } or { assistant: \"#{ANY}\" }") unless turn.is_a?(Hash) && turn.size == 1
        role, text = turn.first
        fail_case.call("each turn must be { user: text } or { assistant: \"#{ANY}\" }") unless %w[user assistant].include?(role)
        fail_case.call("a prior reply must be \"#{ANY}\": the runner runs it live") if role == "assistant" && text != ANY
        fail_case.call("a visitor message must be non-empty text") if role == "user" && !(text.is_a?(String) && text.strip.present?)
        role
      end
      fail_case.call("turns must start and end with a visitor message") unless roles.first == "user" && roles.last == "user"
      fail_case.call("turns must alternate between the visitor and the attendant") if roles.each_cons(2).any? { |one, other| one == other }

      turns.filter_map { |turn| turn["user"] }
    end
    private_class_method :messages

    def self.expectations(expect, suite, fail_case)
      fail_case.call("expect must name at least one key") unless expect.is_a?(Hash) && expect.any?
      expect.each do |key, value|
        fail_case.call("unknown expectation key #{key}") unless KEYS.key?(key)
        fail_case.call("#{key}: #{value.inspect} is not a value it takes") unless KEYS.fetch(key).call(value)
      end
      untooled = expect.fetch("tool_args", {}).keys - Array(expect["tools"])
      if expect.key?("tools") && untooled.any?
        fail_case.call("tool_args names #{untooled.join(", ")}, which the case does not expect to be called")
      end
      fail_case.call("#{suite} cases need a rule key besides the rubric") if RULED_SUITES.include?(suite) && expect.keys == [ "rubric" ]

      expect.freeze
    end
    private_class_method :expectations

    def initialize(cases)
      repeated = cases.map(&:id).tally.find { |_, count| count > 1 }
      raise Invalid, "#{repeated.first}: the id appears twice" if repeated

      @cases = cases.freeze
    end

    def all = @cases

    def runnable = @cases.select(&:runnable?)

    def find(id) = @cases.find { |kase| kase.id == id }
  end
end
