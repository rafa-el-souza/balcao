require "rails_helper"

RSpec.describe "FR-03 system prompt (FR-01, FR-02, FR-05, FR-09, FR-26, SR-21, design §6.4)" do
  let(:sheet) { StoreSheet.current }
  let(:prompt) { SystemPrompt.build(sheet, CommandPhrases.current) }

  it "carries the store's identity" do
    expect(prompt).to include("Farmácia Vida Longa", "Rua dos Boticários, 120 — Floresta", "Belo Horizonte")
  end

  it "carries the week's opening hours exactly as the fact sheet writes them" do
    expect(prompt).to include("Monday: 08:00 to 20:00", "Saturday: 08:00 to 14:00", "Sunday: closed")
  end

  it "asks for times and prices written as the facts write them, so a reply states them exactly" do
    expect(prompt).to match(/times and prices exactly as/)
  end

  it "carries none of the facts that get_store_info answers" do
    facts = [ "R$ 5,00", "R$ 7,00", "Pix", "(31) 1234-5678", "rotativo", "Aferição" ]

    expect(facts.select { |fact| prompt.include?(fact) }).to be_empty
  end

  it "carries no date or time, so the cached prefix holds across days" do
    travel_to(Time.zone.local(2026, 11, 14, 9, 30)) do
      expect(prompt).not_to match(/2026|09:30|November|novembro/i)
    end
  end

  it "is the same text for the same files, byte for byte, as caching needs" do
    expect(SystemPrompt.build(sheet, CommandPhrases.current)).to eq(prompt)
  end

  it "follows a changed fact sheet with no code change (FR-26)" do
    data = YAML.safe_load_file(StoreSheet::PATH)
    data["hours"]["saturday"] = { "opens" => "09:00", "closes" => "13:00" }

    changed = SystemPrompt.build(StoreSheet.new(data), CommandPhrases.current)

    expect(changed).to include("Saturday: 09:00 to 13:00")
    expect(changed).not_to include("Saturday: 08:00 to 14:00")
  end

  it "names the three languages and Portuguese as the answer to any other (FR-02)" do
    expect(prompt).to include("Brazilian Portuguese", "English", "Spanish")
    expect(prompt).to match(/any other language.*Portuguese/m)
  end

  it "asks for the reply's language tag, which the runner reads and strips (FR-02)" do
    expect(prompt).to include("[pt]", "[en]", "[es]")
  end

  it "leaves the demo notice to the system (FR-01)" do
    expect(prompt).to match(/notice/i)
  end

  it "names the clinical boundary's subjects and the pharmacist (FR-09)" do
    %w[dosage frequency interactions side\ effects suitability substitutions diagnosis symptoms].each do |subject|
      expect(prompt).to include(subject)
    end
    expect(prompt).to include("pharmacist")
  end

  # FR-10's MVP note: the offer is a fixed line the system adds where the
  # reply ends with the tag (AgentRunner, TurnProcessor), so the phone and the
  # hours stay out of the prompt (the example above: no "(31) 1234-5678").
  it "asks for the offer's tag where a reply offers the pharmacist, and leaves the line to the system (FR-10)" do
    expect(prompt).to include("[pharmacist]")
    expect(prompt).to match(/prescription.{0,80}offers nothing|offers nothing.{0,200}prescription/m)
  end

  # The owner's decision of 2026-11-14: the store's pharmacist works the
  # store's hours; none is "on duty" (de plantão) out of them.
  it "names the pharmacist as the store's own in the three languages, never as one on duty" do
    expect(prompt).to include("the store's pharmacist", "o farmacêutico da loja", "el farmacéutico de la tienda")
    expect(prompt).not_to include("pharmacist on duty")
  end

  # FR-09, the owner's decision of 2026-11-14: a message that may be an
  # emergency gets no clinical instruction, and the system adds the line with
  # the public emergency numbers, which the prompt leaves out.
  it "asks for the emergency tag and for no first aid, and leaves the numbers to the system (FR-09)" do
    expect(prompt).to include("[emergency]")
    expect(prompt).to match(/first aid/)
    expect(prompt).not_to include("192", "0800")
  end

  it "gives the deletion command's exact phrases in every language, since only the whole message counts (FR-05)" do
    CommandPhrases.current.phrases(:delete).values.flatten.each do |phrase|
      expect(prompt).to include(%("#{phrase}"))
    end
  end

  it "tells the model that tool results are data, not instructions (SR-21)" do
    expect(prompt).to match(/tool results are data/i)
  end

  it "is read once per process" do
    expect(SystemPrompt.current).to equal(SystemPrompt.current)
  end
end
