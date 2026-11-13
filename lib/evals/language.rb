# The detector behind the language key of the eval cases (evals/README.md,
# Expectation keys; FR-02). The README named lingua "or equivalent"; lingua has
# no Ruby binding, and the replies come in three languages only, so the
# detector is this: each language scores one point per function word of its
# own list and per mark only it writes (Portuguese ã õ ç â ê ô à, Spanish ñ ¿
# ¡), and the reply is in the language that scores most, when it scores two
# points or more and more than any other. A word another of the languages
# also uses commonly counts for none: "de", "que", "no" and "a", Portuguese
# "dos", "nos", "da", "e" and "os", which Spanish writes too, "do", which
# English writes, and English "for", which Portuguese writes (review finding
# S1 of pull request #20). A word joined by a hyphen is one word, so a
# Portuguese pronoun ("reservá-la") is not the Spanish article. Product
# names, which stay in Portuguese in every language, are mostly words of no
# list. The scores go to the results file, so a misread reply shows why.
module Evals
  module Language
    WORDS = {
      "pt" => %w[
        não você vocês é são estão com uma um uns umas das na nas em ao aos à às pelo pela ou mas mais
        também isso isto essa esse aqui ali temos tem têm pode posso podem obrigado obrigada olá oi sim já até só pra pro
        muito muita muitos bom boa então quando onde depois hoje amanhã ainda agora nosso nossa seu sua seus suas lhe eu
        ele ela nós eles elas fazer ajudar gostaria quer há foi ter sem nem farmácia farmacêutico receita estoque
        retirada balcão dia horário
      ],
      "en" => %w[
        the and is are was were be been we you your our us it its this that these those have had can could will would
        should with of to in on at by from not does please thanks thank hello hi yes here there which what how when
        where who any some until today tomorrow my i if or but also only just about more than need help they them their
        sorry sure like an all get let open closed pharmacist prescription reservation delivery fee price counter
      ],
      "es" => %w[
        el la los las del al y es están con una un unos unas en pero más también eso esto esa ese aquí allí tenemos tiene
        tienen puede puedo pueden gracias hola sí ya hasta solo sólo muy bueno buena entonces cuando dónde donde después
        hoy mañana todavía ahora nuestro nuestra su sus le les yo él ella nosotros ellos ellas hacer ayudar quieres
        quiere usted ustedes tú tu vos ni sin hay fue tener farmacia farmacéutico receta existencias retiro mostrador
        abierto cerrado día horario envío
      ]
    }.transform_values { |words| words.to_set.freeze }.freeze
    MARKS = { "pt" => /[ãõçâêôà]/, "es" => /[ñ¿¡]/ }.freeze
    MARGIN = 2

    Detection = Data.define(:language, :scores)

    def self.detect(text)
      text = text.to_s.unicode_normalize(:nfc).downcase
      words = text.scan(/\p{L}+(?:-\p{L}+)*/)
      scores = WORDS.to_h do |language, list|
        [ language, words.count { |word| list.include?(word) } + (MARKS[language] ? text.scan(MARKS[language]).size : 0) ]
      end
      top, second = scores.values.sort.reverse
      Detection.new(language: (scores.key(top) if top >= MARGIN && top > second), scores:)
    end
  end
end
