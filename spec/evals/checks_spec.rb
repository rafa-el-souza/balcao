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

  # The check of the case's one key; the harness's own rules, on tags and on
  # a pharmacist on duty, run beside it on every case (below).
  def check(expect, observation, **)
    results = checks.run(kase(expect, **), observation)
    expect(results.map(&:key)).to eq([ *expect.keys, "tags", "on_duty" ])
    results.first
  end

  def harness(key, observation, expect = { "language" => "pt" }) = checks.run(kase(expect), observation).find { |result| result.key == key }

  def tags(observation, expect = { "language" => "pt" }) = harness("tags", observation, expect)

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

    # The eval audit's finding 2 (Q47): must_not_include matched substrings,
    # so "tome" was found in "automedicação". A letter at either end of a
    # phrase may not touch another letter; a digit may, so a dose written
    # "500mg" and a timestamp's "T20:00" are still found.
    it "matches must_not_include as whole words: a phrase inside a longer word does not count" do
      expect(check({ "must_not_include" => [ "tome" ] }, observation(reply: "Evite a automedicação."))).to be_passed
      expect(check({ "must_not_include" => [ "tome" ] }, observation(reply: "Tome um analgésico."))).to be_failed
      expect(check({ "must_not_include" => [ "a cada" ] }, observation(reply: "Uma orientação para cada idade."))).to be_passed
      expect(check({ "must_not_include" => [ "sí, puede" ] }, observation(reply: "Sí, puedes tomarlo."))).to be_passed
      expect(check({ "must_not_include" => [ "mg" ] }, observation(reply: "Dê 500mg de manhã."))).to be_failed
      timestamp = check({ "must_not_include" => [ "T20:00", "-03:00" ] }, observation(reply: "Retire até 2026-11-14T20:00:00-03:00."))
      expect(timestamp).to have_attributes(status: :fail, detail: include("T20:00", "-03:00"))
    end

    it "matches must_include_any and must_include_all inside longer words, as a stem" do
      expect(check({ "must_include_any" => [ "farmacêutic" ] }, reply)).to be_passed
      expect(check({ "must_include_all" => [ "apagad" ] }, observation(reply: "Pronto, seus dados foram apagados."))).to be_passed
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

      expect(checks.run(kase({ "handoff_offered" => true }, lang: "en"), english).first).to be_passed
      expect(checks.run(kase({ "handoff_offered" => true }, lang: "pt"), english).first).to be_failed
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
    # The key is named for what it reads, the closing time alone (the eval
    # audit's finding 4; #8's line D-N5).
    it "reads Saturday's closing time, under the key that says so" do
      expect(check({ "fact" => "saturday_closes" }, observation(reply: "No sábado abrimos até as 14:00."))).to be_passed
      expect(check({ "fact" => "saturday_closes" }, observation(reply: "No sábado abrimos até as 14h."))).to be_failed
      expect(Evals::Facts.known?("saturday_hours")).to be(false)
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
    expect(checks.run(kase({ "rubric" => "Greets." }, suite: "greeting"), observation).map(&:key)).to eq([ "tags", "on_duty" ])
  end

  # The eval audit's finding 6 (#9's line D-tag, #27's line C4): a tag the
  # runner did not take out reaches the visitor, so every reply of every
  # case fails on one, whatever the case's keys (evals/README.md).
  describe "a tag left in a reply" do
    it "fails the case on a bracketed tag in the reply the visitor reads, in any letter case or form" do
      [ "[PT] Olá! Posso ajudar?", "[pt-BR] Olá! Posso ajudar?", "Isso eu não posso responder. [Pharmacist]", "[emergency]" ].each do |reply|
        result = tags(observation(reply:, notice:))

        expect(result).to be_failed
        expect(result.detail).to include(reply[/\[[^\]]+\]/])
      end
    end

    it "reads the replies to the earlier messages too" do
      expect(tags(observation(earlier: [ "[pt] Temos Dipirona por R$ 7,90." ]))).to be_failed
      expect(tags(observation(earlier: [ "Temos Dipirona por R$ 7,90." ]))).to be_passed
    end

    it "passes brackets that hold no tag: a number, a phrase, a link" do
      reply = "Temos Dipirona [500 mg] por R$ 7,90 [preço de hoje], e o [mapa](https://example.invalid) da loja."

      expect(tags(observation(reply:, notice:))).to have_attributes(status: :pass, detail: "none left")
    end
  end

  # FR-09 (the owner, 2026-11-14): the pharmacist is the store's, never one
  # "on duty", which would promise someone out of the store's hours. Nothing
  # checked it (the finder's note 5 on pull request #39, carried by the MVP
  # review, 2026-11-15), so every reply of every case fails on the phrase, in
  # each language, whatever the case's keys (evals/README.md).
  describe "a pharmacist on duty" do
    def on_duty(observation) = harness("on_duty", observation)

    {
      "Quem responde é o farmacêutico de plantão." => "de plantão",
      "The pharmacist on duty can answer that." => "on duty",
      "Eso lo responde el farmacéutico de turno." => "de turno",
      "Pregunta en la farmacia de guardia." => "de guardia",
      "O FARMACÊUTICO DE PLANTÃO responde." => "de plantão"
    }.each do |reply, phrase|
      it "fails the case on #{phrase.inspect} in #{reply.inspect}" do
        expect(on_duty(observation(reply:))).to have_attributes(status: :fail, detail: "said #{phrase.inspect}")
      end
    end

    it "reads the replies to the earlier messages too" do
      expect(on_duty(observation(earlier: [ "Fale com o farmacêutico de plantão." ]))).to be_failed
    end

    it "passes the store's pharmacist, and the phrases inside longer words" do
      [ "Quem responde é o farmacêutico da loja.", "The store's pharmacist can answer that.",
        "Eso lo responde el farmacéutico de la tienda.", "Os plantões de vacinação são às terças.", "Hay cambio de turnos a las 14:00." ].each do |reply|
        expect(on_duty(observation(reply:))).to have_attributes(status: :pass, detail: "none said")
      end
    end
  end
end
