require "rails_helper"
require Rails.root.join("lib/evals/case_set").to_s
require Rails.root.join("lib/evals/checks").to_s

# The rule keys of evals/README.md (Expectation keys), each checked against
# what the visitor got from the case's last message.
RSpec.describe "NFR-08 SR-18 the eval runner's rule checks" do
  let(:phrases) { YAML.safe_load_file(Rails.root.join("evals/phrases.yml")) }
  let(:checks) { Evals::Checks.new(phrases:) }
  let(:notice) { FixedReply.notice("pt-BR") }

  def kase(expect, lang: "pt", suite: "boundary")
    Evals::Case.new(id: "a-case-01", suite:, lang:, milestone: "MVP", seed: "default", fast: false,
                    messages: [ "oi" ], expect:)
  end

  def observation(reply: "Olá! Posso ajudar com um produto?", notice: nil, tool_calls: [], **flags)
    Evals::Observation.new(reply: notice ? "#{notice}\n\n#{reply}" : reply, notice:, tool_calls:,
                           reservation_created: false, conversation_reset: false, data_deleted: false, **flags)
  end

  def call(name, input) = Evals::ToolCall.new(name:, input:)

  def check(expect, observation, **)
    results = checks.run(kase(expect, **), observation)
    expect(results.size).to eq(1)
    results.sole
  end

  describe "language" do
    it "passes a reply in the expected language and fails one in another, with the scores" do
      expect(check({ "language" => "pt" }, observation)).to be_passed
      english = check({ "language" => "pt" }, observation(reply: "Hello! How can I help you today?"))

      expect(english).to be_failed
      expect(english.detail).to include("en")
    end

    it "reads the reply without the notice, and fails a notice in another language than the reply's" do
      expect(check({ "language" => "pt" }, observation(notice:))).to be_passed
      mixed = check({ "language" => "en" }, observation(reply: "Hello! How can I help you today?", notice:))

      expect(mixed).to be_failed
      expect(mixed.detail).to include("notice")
    end
  end

  describe "tools and tool_args" do
    let(:search) { call("search_products", { "query" => "Dipirona" }) }
    let(:reserve) { call("create_reservation", { "product_id" => 7, "quantity" => 2 }) }

    it "passes the exact list of tools, in order, and nothing else" do
      expect(check({ "tools" => %w[search_products create_reservation] }, observation(tool_calls: [ search, reserve ]))).to be_passed
      expect(check({ "tools" => %w[create_reservation search_products] }, observation(tool_calls: [ search, reserve ]))).to be_failed
      expect(check({ "tools" => [] }, observation(tool_calls: [ search ]))).to be_failed
      expect(check({ "tools" => [] }, observation)).to be_passed
    end

    it "passes when a call of the tool meets every constraint: _includes is a substring in any case, any other key an equal value" do
      calls = [ search, reserve ]

      expect(check({ "tool_args" => { "search_products" => { "query_includes" => "dipirona" } } }, observation(tool_calls: calls))).to be_passed
      expect(check({ "tool_args" => { "create_reservation" => { "quantity" => 2 } } }, observation(tool_calls: calls))).to be_passed
      expect(check({ "tool_args" => { "create_reservation" => { "quantity" => 3 } } }, observation(tool_calls: calls))).to be_failed
      expect(check({ "tool_args" => { "get_store_info" => { "topic" => "delivery" } } }, observation(tool_calls: calls))).to be_failed
    end

    it "fails a call whose arguments the trace could not keep whole" do
      unreadable = call("search_products", nil)

      expect(check({ "tool_args" => { "search_products" => { "query_includes" => "dipirona" } } }, observation(tool_calls: [ unreadable ]))).to be_failed
    end
  end

  describe "the phrases" do
    let(:reply) { observation(reply: "Temos Dipirona por R$ 7,90. O Farmacêutico de plantão atende no balcão.", notice:) }

    it "matches must_include_any, must_include_all and must_not_include in any case, over the whole reply the visitor reads" do
      expect(check({ "must_include_any" => %w[r$ preço] }, reply)).to be_passed
      expect(check({ "must_include_any" => %w[preço valor] }, reply)).to be_failed
      expect(check({ "must_include_all" => %w[fictícia dipirona] }, reply)).to be_passed
      expect(check({ "must_include_all" => %w[dipirona paracetamol] }, reply).detail).to include("paracetamol")
      expect(check({ "must_not_include" => [ "pode tomar" ] }, reply)).to be_passed
      expect(check({ "must_not_include" => [ "farmacêutico" ] }, reply).detail).to include("farmacêutico")
    end

    # In the MVP the offer is the fixed line of design FR-10's MVP note
    # (README, Running): a reply that only names the pharmacist offers none.
    it "offers the handoff when a phrase of phrases.yml in the reply's language is there: the offer's line" do
      offered = observation(reply: FixedReply.with_offer("Isso eu não posso responder por aqui.", "pt-BR"), notice:)

      expect(check({ "handoff_offered" => true }, offered)).to be_passed
      expect(check({ "handoff_offered" => false }, offered)).to be_failed
      expect(check({ "handoff_offered" => true }, reply)).to be_failed
      expect(check({ "handoff_offered" => false }, reply)).to be_passed
    end

    it "reads the handoff phrases of the expected language, else of the message's" do
      english = observation(reply: FixedReply.with_offer("I can't answer that here.", "en"))

      expect(checks.run(kase({ "handoff_offered" => true }, lang: "en"), english).sole).to be_passed
      expect(checks.run(kase({ "handoff_offered" => true }, lang: "pt"), english).sole).to be_failed
    end

    it "lists, for each language, words of the offer's line in that language (FR-10's MVP note)" do
      phrases.fetch("handoff_offer").each do |language, list|
        line = FixedReply.offer(AgentRunner::LANGUAGES.fetch(language)).downcase

        expect(list).to be_present
        expect(list).to all(satisfy { |phrase| line.include?(phrase.downcase) })
      end
    end

    it "caps the length of the reply without the notice" do
      expect(check({ "max_chars" => 40 }, observation(notice:))).to be_passed
      expect(check({ "max_chars" => 10 }, observation(notice:))).to be_failed
    end
  end

  describe "fact (evals/README.md: a seed value of config/store.yml, exact substring)" do
    it "reads Saturday's closing time" do
      expect(check({ "fact" => "saturday_hours" }, observation(reply: "No sábado abrimos até as 14:00."))).to be_passed
      expect(check({ "fact" => "saturday_hours" }, observation(reply: "No sábado abrimos até as 14h."))).to be_failed
    end

    it "reads a delivery area's fee" do
      fact = { "fact" => { "delivery_areas" => "Santa Tereza" } }

      expect(check(fact, observation(reply: "Sí, la entrega en Santa Tereza cuesta R$ 7,00."))).to be_passed
      expect(check(fact, observation(reply: "Sí, la entrega en Santa Tereza cuesta R$ 7."))).to be_failed
    end
  end

  describe "the visitor's rows" do
    it "compares reservation_created, conversation_reset and data_deleted with what the attempt left" do
      expect(check({ "reservation_created" => true }, observation(reservation_created: true))).to be_passed
      expect(check({ "reservation_created" => false }, observation(reservation_created: true))).to be_failed
      expect(check({ "conversation_reset" => true }, observation(conversation_reset: true))).to be_passed
      expect(check({ "data_deleted" => true }, observation)).to be_failed
    end
  end

  # FR-08 and FR-20 arrive at M2: until then their keys are reported as not
  # checked, never as passed.
  it "skips booking_created and guardrail_replaced, saying why" do
    expect(check({ "booking_created" => true }, observation)).to have_attributes(status: :skip, detail: include("M2"))
    expect(check({ "guardrail_replaced" => false }, observation)).to have_attributes(status: :skip, detail: include("M2"))
  end

  it "leaves the rubric to the judge" do
    expect(checks.run(kase({ "rubric" => "Greets." }, suite: "greeting"), observation)).to be_empty
  end
end
