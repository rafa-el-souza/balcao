require "rails_helper"

RSpec.describe "FR-04 FR-05 FR-12 FR-19 command phrases, matched before the model" do
  subject(:commands) { CommandPhrases.load(Rails.root.join("config/commands.yml")) }

  it "knows the five commands in the three languages" do
    expect(commands.names).to contain_exactly(:reset, :delete, :trace, :start, :help)
    expect(commands.phrases(:reset).keys).to contain_exactly("pt", "en", "es")
  end

  # FR-19: Telegram requires /start and /help of every bot; the web chat
  # matches them too (FR-18). A command may carry the bot's own username, and
  # /start the parameter of a deep link, ignored until FR-23 reads it (M5).
  {
    "/start" => :start, "/help" => :help, "/help@BalcaoDemoBot" => :help, "/START@balcaodemobot" => :start,
    "/apagar@BalcaoDemoBot" => :delete, "/start ref_landing-01" => :start, "/start@BalcaoDemoBot qr" => :start
  }.each do |text, command|
    it "matches #{text.inspect} to #{command}" do
      expect(commands.match(text)).to eq command
    end
  end

  {
    "another bot's username" => "/help@OtherDemoBot",
    "a parameter after another command" => "/help me",
    "two words after /start" => "/start ref landing",
    "a parameter longer than a deep link's 64 characters" => "/start #{"a" * 65}",
    "the username alone" => "@BalcaoDemoBot"
  }.each do |label, text|
    it "does not match #{label}" do
      expect(commands.match(text)).to be_nil
    end
  end

  # FR-19, agreement first (the owner, 2026-11-14): the phrases the ask's
  # button sends, or a person types, count as the agreement while the bot
  # holds no row of that person. They are not commands: once the row exists,
  # they are a message like any other.
  describe "the agreement's phrases" do
    [ "Concordo", "concordo.", "  CONCORDO! ", "eu concordo", "I agree", "i agree.", "Acepto", "acepto!", "Concordo 👍",
      '"Concordo"' ].each do |text|
      it "takes #{text.inspect} as the agreement, and never as a command" do
        expect(commands.agreement?(text)).to be(true)
        expect(commands.match(text)).to be_nil
      end
    end

    [ "concordo com o preço", "não concordo", "/start", "ok", "", nil ].each do |text|
      it "does not take #{text.inspect} as the agreement" do
        expect(commands.agreement?(text)).to be(false)
      end
    end

    it "names, in each language, the phrase the ask's button sends, the one the privacy page names" do
      expect(%w[pt en es].map { |language| commands.agreement(language) }).to eq([ "Concordo", "I agree", "Acepto" ])
    end
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

  # FR-05 (the owner, 2026-11-15; review finding N8 of pull request #8 and
  # the MVP review's verifier): quotation marks around the phrase and the
  # punctuation or emoji after it do not count, for every command.
  {
    "an emoji after it, the requirement's own example" => [ "apagar meus dados 🙏", :delete ],
    "an emoji with a skin tone" => [ "apagar meus dados 👍🏽", :delete ],
    "an emoji with its variation selector" => [ "/apagar ❤️", :delete ],
    "a face made of punctuation" => [ "delete my data :)", :delete ],
    "several marks" => [ "apagar meus dados!!!", :delete ],
    "straight quotation marks" => [ '"apagar meus dados"', :delete ],
    "curly quotation marks" => [ "“apagar meus dados”", :delete ],
    "single quotation marks" => [ "'delete my data'", :delete ],
    "guillemets" => [ "«borrar mis datos»", :delete ],
    "an opening mark and quotation marks" => [ "¿“borrar mis datos”", :delete ],
    "an opening question mark alone" => [ "¿borrar mis datos", :delete ],
    "an emoji after another command" => [ "/reiniciar 🙏", :reset ],
    "an emoji after the trace's question" => [ "como você funciona? 🤔", :trace ]
  }.each do |label, (text, command)|
    it "matches #{text.inspect} to #{command} (#{label})" do
      expect(commands.match(text)).to eq command
    end
  end

  # FR-05 (the owner, 2026-11-15): a deletion phrase that ends in a question
  # mark is a question, which goes to the attendant, who says how to delete;
  # the rule is the deletion's alone ("como você funciona?" stays the trace).
  [
    "apagar meus dados?", "/apagar?", "delete my data?", "¿borrar mis datos?", "apagar meus dados? 🙏",
    "apagar meus dados 🙏?", "apagar meus dados?!", "apagar meus dados ？", "apagar meus dados❓", '"apagar meus dados?"'
  ].each do |text|
    it "takes #{text.inspect} as a question for the attendant, not the deletion" do
      expect(commands.match(text)).to be_nil
    end
  end

  {
    "an emoji before the phrase" => "🙏 apagar meus dados",
    "an emoji inside the phrase" => "apagar 🙏 meus dados",
    "words after an emoji" => "apagar meus dados 🙏 por favor",
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

  {
    "reset" => %w[pt en es], "/reset" => %w[pt en es], "start over" => %w[en], "/reiniciar" => %w[pt es], "recomeçar" => %w[pt],
    "Borrar mis datos." => %w[es], "/trace" => %w[pt en es], "tem dipirona?" => []
  }.each do |text, languages|
    it "names the languages that list #{text.inspect}: #{languages.inspect}, so a reply can follow the phrase (FR-02)" do
      expect(CommandPhrases.current.languages(text)).to eq(languages)
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

    it "refuses a file without the agreement's phrases" do
      expect { load_with(data.except("agree")) }.to raise_error(CommandPhrases::Invalid, /commands must be exactly/)
    end

    it "refuses an agreement's phrase that is also a command's" do
      data["agree"]["pt"] << "/start"

      expect { load_with(data) }.to raise_error(CommandPhrases::Invalid, /"\/start" belongs to start and agree/)
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
