# The visitor's commands, config/commands.yml (FR-04, FR-05, FR-12, FR-19):
# matched before the model is called, so no model output and no prompt
# injection can trigger one (FR-05). A message is a command only when,
# normalised, it is exactly one of the phrases, and a deletion phrase
# followed by a question mark is a question; the file's header says both.
# The same file lists the phrases of Telegram's agreement (FR-19), which are
# never a command and are normalised the same way.
class CommandPhrases
  PATH = Rails.root.join("config/commands.yml")
  NAMES = %w[reset delete trace start help].freeze
  AGREEMENT = "agree".freeze
  LANGUAGES = %w[pt en es].freeze
  # A command typed with the bot's username is that command, and /start may
  # carry a deep link's parameter (FR-19): up to 64 of A-Z, a-z, 0-9, _ and -.
  BOT_MENTION = %r{\A(/[a-z0-9_]+)@#{Telegram::Bot::USERNAME.downcase}(?=\s|\z)}
  DEEP_LINK = %r{\A/start [a-z0-9_-]{1,64}\z}
  # Before a phrase: spaces, an opening ¿ or ¡, and quotation marks.
  OPENING = /\A[\s¿¡"'“”‘’«»‹›„‚]+/
  # After it: spaces, punctuation, symbols and the pieces emoji are made of
  # (joiners, keycaps; NFKD has already taken the variation selectors), but
  # not U+FFFD, which stands for bytes that were not UTF-8.
  TAIL = /[[\s\p{P}\p{S}\p{Extended_Pictographic}\p{Cf}\p{Me}]&&[^\uFFFD]]+\z/
  # A question mark in what follows a deletion phrase: NFKD reads the
  # full-width "？" and "⁉" as "?".
  QUESTION = /[?‽❓❔]/

  class Invalid < StandardError; end

  def self.current = @current ||= load(PATH)

  def self.load(path)
    new(YAML.safe_load_file(path))
  rescue Psych::Exception => e
    raise Invalid, "#{path}: #{e.message}"
  end

  # Case, accents, surrounding and repeated spaces, an opening ¿ or ¡,
  # quotation marks around the phrase and the punctuation or emoji after it
  # do not count (FR-05, the owner, 2026-11-15), nor the bot's username after
  # a command and a deep link's parameter after /start; nothing else is
  # removed. Bytes that are not UTF-8 become U+FFFD, so such a message is
  # never a command and never raises before the turn starts.
  def self.normalize(text) = split(text).first

  # The phrase a message is, normalized, and what followed it.
  def self.split(text)
    text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    text = text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/\s+/, " ").strip.sub(OPENING, "")
    tail = text[TAIL].to_s
    text = text.delete_suffix(tail).sub(BOT_MENTION, '\1')
    [ text.match?(DEEP_LINK) ? "/start" : text, tail ]
  end

  def initialize(data)
    keys = NAMES + [ AGREEMENT ]
    raise Invalid, "commands must be exactly #{keys.join(", ")}" unless data.is_a?(Hash) && data.keys.sort == keys.sort

    @phrases = NAMES.to_h { |name| [ name.to_sym, check_languages(data[name], name) ] }
    @agreement = check_languages(data[AGREEMENT], AGREEMENT)
    owners = index(@phrases.merge(AGREEMENT.to_sym => @agreement))
    @commands = owners.reject { |_, owner| owner == AGREEMENT.to_sym }.freeze
    @agreements = owners.filter_map { |key, owner| key if owner == AGREEMENT.to_sym }.to_set.freeze
    @languages = languages_index(@phrases)
  end

  def names = @phrases.keys

  def phrases(name) = @phrases.fetch(name)

  # :reset, :delete, :trace, :start, :help, or nil when the message is not a
  # command. A deletion phrase followed by a question mark is a question, for
  # the attendant, who says how to delete (FR-05, the owner, 2026-11-15); the
  # rule is the deletion's alone, so "como você funciona?" is the trace.
  def match(text)
    phrase, tail = self.class.split(text)
    name = @commands[phrase]
    name == :delete && tail.match?(QUESTION) ? nil : name
  end

  # Whether the message is one of the agreement's phrases (FR-19), which
  # counts only while the bot holds no row of the person.
  def agreement?(text) = @agreements.include?(self.class.normalize(text))

  # The phrase the ask's button sends in this language ("pt", "en", "es").
  def agreement(language) = @agreement.fetch(language).first

  # The languages whose list holds the phrase ("reset" is English only,
  # "/reiniciar" Portuguese and Spanish), so a confirmation can follow the
  # language the visitor wrote in (FR-02); empty for a message that is not a
  # command.
  def languages(text) = @languages.fetch(self.class.normalize(text), [])

  private

  def check_languages(languages, name)
    raise Invalid, "#{name} must list pt, en and es" unless languages.is_a?(Hash) && languages.keys.sort == LANGUAGES.sort

    languages.each do |language, phrases|
      raise Invalid, "#{name}.#{language} must be a non-empty list" unless phrases.is_a?(Array) && phrases.any?
      raise Invalid, "#{name}.#{language} has a blank phrase" if phrases.any? { |phrase| !phrase.is_a?(String) || self.class.normalize(phrase).empty? }
    end
    languages.transform_values { |phrases| phrases.map(&:freeze).freeze }.freeze
  end

  def languages_index(phrases)
    phrases.values.flat_map(&:to_a).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(language, list), index|
      list.each do |phrase|
        key = self.class.normalize(phrase)
        index[key] << language unless index[key].include?(language)
      end
    end.transform_values { |languages| LANGUAGES & languages }.to_h.freeze
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
