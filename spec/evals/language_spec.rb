require "rails_helper"
require Rails.root.join("lib/evals/language").to_s

# The language key's detector (evals/README.md, Expectation keys): a reply is
# told by the function words and the marks only one of the three languages
# uses. Product names stay in Portuguese in every language (FR-02), so they
# must not decide it.
RSpec.describe "FR-02 the eval runner tells a reply's language" do
  def detect(text) = Evals::Language.detect(text).language

  it "tells Portuguese, English and Spanish replies apart" do
    expect(detect("Temos sim! Dipirona 500 mg, 10 comprimidos, por R$ 7,90. Quer que eu reserve uma caixa pra você?")).to eq("pt")
    expect(detect("Yes, we have Dipirona 500 mg, 10 comprimidos, for R$ 7,90. Would you like me to reserve a box?")).to eq("en")
    expect(detect("¡Sí, tenemos! Ibuprofeno 400 mg, 10 cápsulas, por R$ 12,50. ¿Quieres que te reserve una caja?")).to eq("es")
  end

  it "tells the declines of the boundary apart, which share most of their words' roots" do
    expect(detect("Isso eu não posso responder por aqui. O farmacêutico de plantão atende no balcão.")).to eq("pt")
    expect(detect("Eso no lo puedo responder por aquí. El farmacéutico de turno te atiende en el mostrador.")).to eq("es")
    expect(detect("I can't answer that here. The pharmacist on duty can help you at the counter.")).to eq("en")
  end

  it "is not swayed by a list of Portuguese product names in an English reply" do
    reply = "We carry these:\nDipirona 500 mg, 10 comprimidos: R$ 7,90\nDipirona gotas 500 mg/ml, 20 ml: R$ 9,50\n" \
            "Curativo adesivo, caixa com 40: R$ 8,90\nWhich one would you like?"

    expect(detect(reply)).to eq("en")
  end

  it "tells nothing from a reply too short or with no words of the three" do
    expect(detect("R$ 7,90")).to be_nil
    expect(detect("Ok!")).to be_nil
    expect(detect("")).to be_nil
  end

  it "gives the scores it decided by, for the results file" do
    detection = Evals::Language.detect("Temos sim, e entregamos em Santa Tereza.")

    expect(detection.scores).to include("pt" => be > detection.scores.fetch("es"))
    expect(detection.scores.keys).to match_array(%w[pt en es])
  end

  it "keeps the three word lists apart, so a word counts for one language only" do
    lists = Evals::Language::WORDS.values

    expect(lists.combination(2).map { |one, other| one & other }).to all(be_empty)
  end
end
