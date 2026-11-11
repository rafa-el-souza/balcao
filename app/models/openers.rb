# The landing's openers, config/openers.yml (FR-21): the chat sends a key and
# the server sends the text that key names. Only a key of the file resolves;
# any other value, of any type, resolves to nothing (threat model SR-34).
class Openers
  PATH = Rails.root.join("config/openers.yml")
  LANGUAGES = %w[pt en es].freeze
  KEY = /\A[a-z0-9_]+\z/

  class Invalid < StandardError; end

  Opener = Data.define(:key, :lang, :text)

  def self.current = @current ||= load(PATH)

  def self.load(path)
    new(YAML.safe_load_file(path))
  rescue Psych::Exception => e
    raise Invalid, "#{path}: #{e.message}"
  end

  def initialize(data)
    raise Invalid, "openers must be a mapping of key to { lang, text }" unless data.is_a?(Hash) && data.any?

    @openers = data.to_h { |key, opener| [ key, check(key, opener) ] }.freeze
  end

  def keys = @openers.keys

  # The opener of an allow-listed key, or nil.
  def fetch(key) = key.is_a?(String) ? @openers[key] : nil

  private

  def check(key, opener)
    raise Invalid, "key #{key.inspect} must be lowercase letters, digits and _" unless key.is_a?(String) && key.match?(KEY)
    raise Invalid, "#{key} must be { lang, text }" unless opener.is_a?(Hash) && opener.keys.sort == %w[lang text]
    raise Invalid, "#{key}.lang must be one of #{LANGUAGES.join(", ")}" unless LANGUAGES.include?(opener["lang"])
    raise Invalid, "#{key}.text must be non-empty text" unless opener["text"].is_a?(String) && opener["text"].strip.present?

    Opener.new(key:, lang: opener["lang"], text: opener["text"].freeze)
  end
end
