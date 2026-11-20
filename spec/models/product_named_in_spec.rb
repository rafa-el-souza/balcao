require "rails_helper"

# #59's C2 and H2 (the owner, 2026-11-20): a reply FR-20's check replaced
# keeps a product's line only for a product the visitor's message names, so a
# product the model chose for a symptom never reaches the visitor as the
# system's own line. A message names a product as the catalogue search reads
# a name: every stem of the product's medicine, its salt set aside, or of the
# head of its name, alike a stem of the message, a typo included. Over the
# real seed.
RSpec.describe "FR-20 FR-09 the products a message names (FR-06)" do
  before { CatalogueSeed.seed! }

  def named(text) = Product.named_in(text, Product.ids).map(&:name)

  it "names every product of the medicine the message names" do
    expect(named("tem dipirona? quanto dou pro meu filho?"))
      .to contain_exactly("Dipirona 500 mg, 10 comprimidos", "Dipirona gotas 500 mg/ml, 20 ml")
  end

  it "names a product by its medicine with no word of its salt, and never by the salt's word" do
    expect(named("tem losartana? posso tomar com ibuprofeno?"))
      .to contain_exactly("Losartana potássica 50 mg, 30 comprimidos", "Ibuprofeno 400 mg, 10 cápsulas")
    expect(named("tem algo com potássio?")).to be_empty
  end

  # The head is every word before the first number or comma, all of them,
  # as the search's partial match reads it: the precise side, since a line
  # left out costs a price and a line too many lists what no one asked for.
  it "names a product by the whole head of its name when its medicine is another word" do
    expect(named("vocês têm vitamina c?")).to eq([ "Vitamina C 1 g, 10 comprimidos efervescentes" ])
    expect(named("tem vitamina d?")).to be_empty
    expect(named("tem termômetro?")).to be_empty
  end

  it "names a product through a typo and an English name one letter away" do
    expect(named("tem dipirna?")).to include("Dipirona 500 mg, 10 comprimidos")
    expect(named("do you have amoxicillin?")).to eq([ "Amoxicilina 500 mg, 21 cápsulas" ])
  end

  it "names nothing for a symptom, a body part or a word every name shares" do
    expect(named("tem alguma coisa pra azia?")).to be_empty
    expect(named("o que é bom pra dor de cabeça e garganta?")).to be_empty
    expect(named("tem algum comprimido efervescente?")).to be_empty
  end

  it "names only among the products it is given" do
    expect(Product.named_in("tem dipirona ou paracetamol?", Product.where(active_ingredient: "paracetamol").ids).map(&:name))
      .to contain_exactly("Paracetamol 750 mg, 20 comprimidos", "Paracetamol gotas 200 mg/ml, 15 ml")
  end

  # Review finding H-B1 of pull request #60 (cliente, the verifier's): the
  # likeness asks levenshtein_less_equal, which refuses a word over 255
  # characters, and a visitor's message of up to 1,000 holds a pasted link or
  # a held-down key as one word, so a replacement broke its turn and the
  # visitor got the fallback after three paid runs.
  it "names what the message names beside a word or a link over 255 characters, which names nothing" do
    expect(named("posso dar dipirona pro meu filho? #{"a" * 300} https://exemplo.com.br/#{"b" * 400}"))
      .to contain_exactly("Dipirona 500 mg, 10 comprimidos", "Dipirona gotas 500 mg/ml, 20 ml")
    expect(named("#{"dipirona" * 40} 12345678901234567890123456789012345678901234567890")).to be_empty
  end

  it "names nothing for an empty message or no products" do
    expect(named("")).to be_empty
    expect(Product.named_in("tem dipirona?", [])).to be_empty
  end
end
