# The fictional pharmacy's fact sheet, config/store.yml (design §1.2, FR-03,
# FR-26): the identity and hours the system prompt carries, and the five
# topics get_store_info answers. Read once per process, so the app restarts
# to pick up an edit; a malformed file raises Invalid naming the key, which
# the spec turns into a red CI rather than a turn that fails in production.
class StoreSheet
  PATH = Rails.root.join("config/store.yml")
  TOPICS = %w[delivery payment services contact parking].freeze
  # Date#wday order: Sunday is 0.
  WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
  CLOSED = "closed".freeze
  TIME = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
  MONEY = /\AR\$ \d{1,3}(?:\.\d{3})*,\d{2}\z/

  class Invalid < StandardError; end

  # One day's opening, as HH:MM strings in São Paulo time (design §1.4).
  Hours = Data.define(:opens, :closes)

  def self.current = @current ||= load(PATH)

  def self.load(path)
    new(YAML.safe_load_file(path))
  rescue Psych::Exception => e
    raise Invalid, "#{path}: #{e.message}"
  end

  attr_reader :identity, :topics

  def initialize(data)
    raise Invalid, "the store sheet must be a mapping" unless data.is_a?(Hash)

    @identity = deep_freeze(check_identity(data["identity"]))
    @hours = check_hours(data["hours"]).freeze
    @topics = deep_freeze(check_topics(data["topics"]))
  end

  # The day's hours, or nil when the store is closed: a business day is a day
  # with hours (design §1.4).
  def hours_on(date) = @hours.fetch(date.wday)

  # What get_store_info returns for a topic, or nil for one that is not among
  # the five (FR-03).
  def topic(name) = @topics[name]

  private

  def check_identity(identity)
    require_mapping(identity, "identity")
    %w[name city].each { |key| require_text(identity[key], "identity.#{key}") }
    identity
  end

  def check_hours(hours)
    require_mapping(hours, "hours")
    raise Invalid, "hours must name the seven days, #{WEEKDAYS.join(", ")}" unless hours.keys.sort == WEEKDAYS.sort

    WEEKDAYS.map { |day| check_day(hours[day], "hours.#{day}") }
  end

  def check_day(day, path)
    return if day == CLOSED
    raise Invalid, "#{path} must be { opens: HH:MM, closes: HH:MM } or #{CLOSED}" unless day.is_a?(Hash) && day.keys.sort == %w[closes opens]

    %w[opens closes].each do |key|
      raise Invalid, "#{path}.#{key} must be HH:MM, got #{day[key].inspect}" unless day[key].is_a?(String) && day[key].match?(TIME)
    end
    raise Invalid, "#{path} closes before it opens" unless day["opens"] < day["closes"]

    Hours.new(opens: day["opens"], closes: day["closes"])
  end

  def check_topics(topics)
    require_mapping(topics, "topics")
    raise Invalid, "topics must be exactly #{TOPICS.join(", ")}" unless topics.keys.sort == TOPICS.sort

    TOPICS.each { |name| require_mapping(topics[name], "topics.#{name}") }
    check_list(topics["delivery"]["areas"], "topics.delivery.areas") do |area, path|
      require_text(area["name"], "#{path}.name")
      require_money(area["fee"], "#{path}.fee")
    end
    check_services(topics["services"]["list"])
    require_text(topics["contact"]["phone"], "topics.contact.phone")
    TOPICS.to_h { |name| [ name, topics[name] ] }
  end

  def check_services(services)
    check_list(services, "topics.services.list") do |service, path|
      %w[key name].each { |key| require_text(service[key], "#{path}.#{key}") }
      require_money(service["price"], "#{path}.price")
      unless [ true, false ].include?(service["prescription_required"])
        raise Invalid, "#{path}.prescription_required must be true or false"
      end
    end
    raise Invalid, "topics.services.list keys must be unique" unless services.map { |service| service["key"] }.uniq.size == services.size
  end

  def check_list(list, path, &check)
    raise Invalid, "#{path} must be a non-empty list" unless list.is_a?(Array) && list.any?

    list.each_with_index do |item, index|
      require_mapping(item, "#{path}[#{index}]")
      check.call(item, "#{path}[#{index}]")
    end
  end

  def require_mapping(value, path)
    raise Invalid, "#{path} must be a mapping" unless value.is_a?(Hash)
  end

  def require_text(value, path)
    raise Invalid, "#{path} must be non-empty text" unless value.is_a?(String) && value.strip.present?
  end

  def require_money(value, path)
    raise Invalid, "#{path} must be written like \"R$ 7,00\", got #{value.inspect}" unless value.is_a?(String) && value.match?(MONEY)
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |item| deep_freeze(item) }
    when Array then value.each { |item| deep_freeze(item) }
    end
    value.freeze
  end
end
