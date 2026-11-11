require "rails_helper"

RSpec.describe "FR-04 FR-05 FR-12 command phrases, matched before the model" do
  subject(:commands) { CommandPhrases.load(Rails.root.join("config/commands.yml")) }

  it "knows the three commands in the three languages" do
    expect(commands.names).to contain_exactly(:reset, :delete, :trace)
    expect(commands.phrases(:reset).keys).to contain_exactly("pt", "en", "es")
  end

  {
    "/reiniciar" => :reset, "recomeçar" => :reset, "reset" => :reset, "reiniciar" => :reset,
    "/apagar" => :delete, "apagar meus dados" => :delete, "delete my data" => :delete, "borrar mis datos" => :delete,
    "/trace" => :trace, "como você funciona?" => :trace
  }.each do |text, command|
    it "matches #{text.inspect}, a phrase the requirements name, to #{command}" do
      expect(commands.match(text)).to eq command
    end
  end

  {
    "upper case and spaces around" => "  Apagar Meus Dados  ",
    "no accents, as phones often type" => "recomecar",
    "a final full stop" => "apagar meus dados.",
    "an exclamation" => "/apagar!",
    "a question without its opening mark" => "cómo funcionas?",
    "two spaces inside" => "apagar  meus dados",
    "a space after the opening mark" => "¿ cómo funcionas?"
  }.each do |label, text|
    it "matches with #{label}" do
      expect(commands.match(text)).not_to be_nil
    end
  end

  {
    "the phrase inside a longer message" => "não quero apagar meus dados",
    "the phrase asked about" => "como faço para apagar meus dados?",
    "a reset mentioned in passing" => "reset de senha",
    "an ordinary message" => "tem dipirona?",
    "an empty message" => "",
    "only spaces" => "   ",
    "nil" => nil,
    "bytes that are not UTF-8" => "apagar meus dados\xFF".b,
    "a broken UTF-8 sequence" => "reset\xC3"
  }.each do |label, text|
    it "does not match #{label}, so only the whole message is a command (FR-05)" do
      expect(commands.match(text)).to be_nil
    end
  end

  it "never gives one phrase to two commands" do
    phrases = commands.names.flat_map { |name| commands.phrases(name).values.flatten.map { |phrase| [ CommandPhrases.normalize(phrase), name ] } }

    expect(phrases.group_by(&:first).transform_values { |pairs| pairs.map(&:last).uniq }.values).to all(have_attributes(size: 1))
  end

  describe "a malformed file is refused" do
    def load_with(data)
      path = Rails.root.join("tmp", "commands-#{SecureRandom.hex(4)}.yml")
      File.write(path, data.to_yaml)
      CommandPhrases.load(path)
    ensure
      FileUtils.rm_f(path)
    end

    let(:data) { YAML.safe_load_file(Rails.root.join("config/commands.yml")) }

    it "refuses a command the requirements do not define" do
      expect { load_with(data.merge("buy" => data["reset"].deep_dup)) }.to raise_error(CommandPhrases::Invalid, /commands must be exactly/)
    end

    it "refuses a command without one of the languages" do
      data["delete"].delete("es")

      expect { load_with(data) }.to raise_error(CommandPhrases::Invalid, /delete must list pt, en and es/)
    end

    it "refuses a phrase given to two commands" do
      data["trace"]["en"] << "reset"

      expect { load_with(data) }.to raise_error(CommandPhrases::Invalid, /"reset" belongs to reset and trace/)
    end

    it "refuses a blank phrase, which would match an empty message" do
      data["reset"]["pt"] << " ? "

      expect { load_with(data) }.to raise_error(CommandPhrases::Invalid, /reset\.pt has a blank phrase/)
    end
  end
end
