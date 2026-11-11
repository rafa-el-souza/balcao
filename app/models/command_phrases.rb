# The visitor's commands, config/commands.yml (FR-04, FR-05, FR-12): matched
# before the model is called, so no model output and no prompt injection can
# trigger one (FR-05). A message is a command only when, normalised, it is
# exactly one of the phrases; the file's header says what normalising ignores.
class CommandPhrases
  PATH = Rails.root.join("config/commands.yml")
  NAMES = %w[reset delete trace].freeze
  LANGUAGES = %w[pt en es].freeze

  class Invalid < StandardError; end

  def self.current = @current ||= load(PATH)

  def self.load(path)
    new(YAML.safe_load_file(path))
  rescue Psych::Exception => e
    raise Invalid, "#{path}: #{e.message}"
  end

  # Case, accents, surrounding and repeated spaces, an opening ¿ or ¡ and the
  # final punctuation do not count; nothing else is removed. Bytes that are
  # not UTF-8 become U+FFFD, so such a message is never a command and never
  # raises before the turn starts.
  def self.normalize(text)
    text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    text = text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/\s+/, " ").strip
    text.delete_prefix("¿").delete_prefix("¡").lstrip.sub(/[\s.!?…]+\z/, "")
  end

  def initialize(data)
    raise Invalid, "commands must be exactly #{NAMES.join(", ")}" unless data.is_a?(Hash) && data.keys.sort == NAMES.sort

    @phrases = NAMES.to_h { |name| [ name.to_sym, check_languages(data[name], name) ] }
    @commands = index(@phrases)
  end

  def names = @phrases.keys

  def phrases(name) = @phrases.fetch(name)

  # :reset, :delete, :trace, or nil when the message is not a command.
  def match(text) = @commands[self.class.normalize(text)]

  private

  def check_languages(languages, name)
    raise Invalid, "#{name} must list pt, en and es" unless languages.is_a?(Hash) && languages.keys.sort == LANGUAGES.sort

    languages.each do |language, phrases|
      raise Invalid, "#{name}.#{language} must be a non-empty list" unless phrases.is_a?(Array) && phrases.any?
      raise Invalid, "#{name}.#{language} has a blank phrase" if phrases.any? { |phrase| !phrase.is_a?(String) || self.class.normalize(phrase).empty? }
    end
    languages.transform_values { |phrases| phrases.map(&:freeze).freeze }.freeze
  end

  def index(phrases)
    phrases.each_with_object({}) do |(name, languages), commands|
      languages.values.flatten.each do |phrase|
        key = self.class.normalize(phrase)
        owner = commands[key]
        raise Invalid, "#{phrase.inspect} belongs to #{owner} and #{name}" if owner && owner != name

        commands[key] = name
      end
    end.freeze
  end
end
