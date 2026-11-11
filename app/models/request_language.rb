# The language of a fixed reply written before any conversation is read: an
# over-limit reply at the edge (FR-14) or a deletion's confirmation (FR-05).
# The page names its language in Accept-Language, which it sets to the
# language it shows (FR-02); the first of the three it names wins, else
# Portuguese.
module RequestLanguage
  LOCALES = { "pt" => :"pt-BR", "en" => :en, "es" => :es }.freeze

  module_function

  def of(accept_language)
    tags = accept_language.to_s.split(",").first(10).each_with_index.map do |part, index|
      tag, *params = part.strip.split(";")
      quality = params.filter_map { |param| param.strip[/\Aq=([01](?:\.\d{0,3})?)\z/, 1] }.first
      [ tag.to_s.strip.downcase.split("-").first, quality ? quality.to_f : 1.0, index ]
    end
    tags.reject { |_, quality, _| quality.zero? }.sort_by { |_, quality, index| [ -quality, index ] }
        .each { |language, _, _| return LOCALES[language] if LOCALES.key?(language) }
    I18n.default_locale
  end
end
