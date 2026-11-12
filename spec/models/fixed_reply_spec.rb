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
