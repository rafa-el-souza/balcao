require "rails_helper"

RSpec.describe "NFR-09 FixedReply, the texts the system writes instead of the model (FR-01, FR-04, FR-05, FR-12, NFR-02, NFR-03)" do
  LOCALES = { "pt-BR" => "pt", "en" => "en", "es" => "es" }.freeze

  describe "the demo notice (FR-01)" do
    LOCALES.each do |locale, language|
      it "says in #{locale} that this is a demo of a fictional pharmacy, for how long messages are kept, and the delete command of its language" do
        notice = FixedReply.notice(locale)
        command = notice[%r{/\w+}]

        expect(notice).to include("7")
        expect(CommandPhrases.current.match(command)).to eq(:delete)
        expect(CommandPhrases.current.phrases(:delete).fetch(language)).to include(command)
      end
    end

    # FR-01 asks for a one-line notice and greeting-pt-01 for one short
    # sentence (the owner's decision of 2026-11-14).
    LOCALES.each_key do |locale|
      it "is one sentence in #{locale}" do
        expect(FixedReply.notice(locale).scan(/[.!?](?:\s|\z)/).size).to eq(1)
      end
    end

    it "carries the words the greeting cases look for (evals/cases.yaml)" do
      expect(FixedReply.notice("pt-BR")).to include("demonstração", "fictícia", "apagar")
      expect(FixedReply.notice("en")).to include("demo", "fictional")
      expect(FixedReply.notice("es")).to include("demostración", "ficticia")
    end

    # The notice is told by its place, the first line of a conversation's
    # first reply (Message#trace_payload, AgentRunner::History), so it must
    # stay one line.
    it "is one line, put before the reply" do
      expect(FixedReply.with_notice("Olá!", "pt-BR")).to eq("#{FixedReply.notice("pt-BR")}\n\nOlá!")
      expect(LOCALES.keys.map { |locale| FixedReply.notice(locale) }).to all(satisfy { |notice| !notice.include?("\n") })
    end
  end

  describe "the reservation line (NFR-02, NFR-03)" do
    let(:product) { create(:product, name: "Dipirona sódica 500 mg, 10 comprimidos") }
    let(:reservations) do
      [ build(:reservation, code: "K7M2QX", quantity: 2, product:, pickup_until: Time.zone.local(2026, 11, 12, 20, 0)),
        build(:reservation, code: "P3W9RT", quantity: 1, product:, pickup_until: Time.zone.local(2026, 11, 12, 20, 0)) ]
    end

    it "names the code, the quantity, the product and the pickup deadline in São Paulo time, one line each" do
      expect(FixedReply.reservations(reservations, "pt-BR"))
        .to eq("Reserva K7M2QX: 2 × Dipirona sódica 500 mg, 10 comprimidos, retirada até 12/11 às 20:00.\n" \
               "Reserva P3W9RT: 1 × Dipirona sódica 500 mg, 10 comprimidos, retirada até 12/11 às 20:00.")
      expect(FixedReply.reservations(reservations.first(1), "en"))
        .to eq("Reservation K7M2QX: 2 × Dipirona sódica 500 mg, 10 comprimidos, pick up by Nov 12 at 20:00.")
      expect(FixedReply.reservations(reservations.first(1), "es"))
        .to eq("Reserva K7M2QX: 2 × Dipirona sódica 500 mg, 10 comprimidos, retiro hasta el 12/11 a las 20:00.")
    end

    it "adds the lines after a text, and nothing when there is none" do
      expect(FixedReply.with_reservations("Desculpe.", reservations.first(1), "pt-BR"))
        .to eq("Desculpe.\n\nReserva K7M2QX: 2 × Dipirona sódica 500 mg, 10 comprimidos, retirada até 12/11 às 20:00.")
      expect(FixedReply.with_reservations("Desculpe.", [], "pt-BR")).to eq("Desculpe.")
    end
  end

  # FR-10's MVP note: until M2 the offer of the pharmacist is a fixed line
  # with the pharmacy's phone and the counter's hours, both from
  # config/store.yml (FR-26), wherever FR-03, FR-06 and FR-09 ask for one.
  # The pharmacist is the store's own, never one "on duty", since the store
  # has none on call out of its hours (the owner's decision of 2026-11-14).
  describe "the offer of the pharmacist (FR-10's MVP note, FR-09)" do
    it "gives the phone and the counter's hours from the store sheet, in each locale" do
      expect(FixedReply.offer("pt-BR"))
        .to eq("Para falar com o farmacêutico da loja, ligue (31) 1234-5678 ou venha ao balcão " \
               "(de segunda a sexta, das 08:00 às 20:00; aos sábados, das 08:00 às 14:00).")
      expect(FixedReply.offer("en"))
        .to eq("To talk to the store's pharmacist, call (31) 1234-5678 or come to the counter " \
               "(Monday to Friday, 08:00 to 20:00; Saturdays, 08:00 to 14:00).")
      expect(FixedReply.offer("es"))
        .to eq("Para hablar con el farmacéutico de la tienda, llama al (31) 1234-5678 o ven al mostrador " \
               "(de lunes a viernes, de 08:00 a 20:00; los sábados, de 08:00 a 14:00).")
    end

    it "follows a changed store sheet with no code change: days with the same hours in a row go together (FR-26)" do
      data = YAML.safe_load_file(StoreSheet::PATH)
      data["topics"]["contact"]["phone"] = "(31) 9999-0000"
      data["hours"]["wednesday"] = "closed"
      data["hours"]["thursday"] = { "opens" => "08:00", "closes" => "18:00" }
      data["hours"]["sunday"] = { "opens" => "08:00", "closes" => "14:00" }

      offer = FixedReply.offer("pt-BR", StoreSheet.new(data))

      expect(offer).to eq("Para falar com o farmacêutico da loja, ligue (31) 9999-0000 ou venha ao balcão " \
                          "(de segunda a terça, das 08:00 às 20:00; às quintas, das 08:00 às 18:00; " \
                          "às sextas, das 08:00 às 20:00; de sábado a domingo, das 08:00 às 14:00).")
    end

    it "names every day of the week in each locale" do
      data = YAML.safe_load_file(StoreSheet::PATH)
      hours = %w[06 07 08 09 10 11 12].map { |opens| { "opens" => "#{opens}:00", "closes" => "22:00" } }
      data["hours"] = StoreSheet::WEEKDAYS.rotate(1).zip(hours).to_h
      sheet = StoreSheet.new(data)

      LOCALES.each_key do |locale|
        expect(FixedReply.offer(locale, sheet)).not_to include("translation missing")
        expect(FixedReply.offer(locale, sheet).scan(";").size).to eq(6)
      end
    end

    it "comes after a text as a paragraph of its own" do
      expect(FixedReply.with_offer("Isso eu não posso responder por aqui.", "pt-BR"))
        .to eq("Isso eu não posso responder por aqui.\n\n#{FixedReply.offer("pt-BR")}")
    end
  end

  # FR-09's decline, the reply to a refusal (threat model SR-19) and, from
  # M2, to a reply the guardrail replaces (FR-20): one or two sentences that
  # decline and name the store's pharmacist; the turn adds the offer after it
  # (TurnProcessor).
  describe "the decline text (FR-09, SR-19)" do
    LOCALES.each_key do |locale|
      it "declines in #{locale} in one or two sentences and names the store's pharmacist" do
        decline = FixedReply.declined(locale)

        expect(decline).to match(/farmacêutico da loja|store's pharmacist|farmacéutico de la tienda/)
        expect(decline.scan(/[.!?](?:\s|\z)/).size).to be_between(1, 2)
        expect(decline).not_to include("\n")
      end
    end
  end

  # FR-09, the owner's decision of 2026-11-14: a message that may be an
  # emergency gets the real public numbers, whatever the store sheet says,
  # since the visitor writing is a real person. SAMU's 192 and Anvisa's free
  # Disque-Intoxicação, 0800 722 6001, checked on that day.
  describe "the emergency line (FR-09)" do
    LOCALES.each_key do |locale|
      it "gives SAMU's 192 and the Disque-Intoxicação's number in #{locale}, in one paragraph" do
        line = FixedReply.emergency(locale)

        expect(line).to include("SAMU", "192", "Disque-Intoxicação", "0800 722 6001")
        expect(line).not_to include("\n")
      end
    end

    it "comes after a text as a paragraph of its own" do
      expect(FixedReply.with_emergency("Ligue agora.", "pt-BR")).to eq("Ligue agora.\n\n#{FixedReply.emergency("pt-BR")}")
    end
  end

  it "writes the trace link into the trace command's reply (FR-12)" do
    expect(FixedReply.command(:trace, "en", url: "https://demo.example/trace/abc"))
      .to eq("Here is how I work in this conversation, step by step: https://demo.example/trace/abc")
  end

  it "has a text for every command, the fallback and the refusal in every locale" do
    LOCALES.each_key do |locale|
      texts = CommandPhrases::NAMES.map { |name| FixedReply.command(name.to_sym, locale, url: "u") } +
              [ FixedReply.fallback(locale), FixedReply.declined(locale) ]
      expect(texts).to all(be_present.and(satisfy { |text| !text.include?("translation missing") }))
    end
  end
end
