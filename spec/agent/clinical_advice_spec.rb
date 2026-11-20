require "rails_helper"

# FR-09 and FR-20: what clinical advice is, written once and read by both
# layers of the boundary. The attendant's prompt and FR-20's check each had
# their list by hand: the norms study of 2026-11-20 found the check counting
# what a medicine does to the body while the prompt did not name it, and the
# owner pointed at the two lists with no test between them (design §10,
# M2-4b). Each layer keeps its own framing and rules around the one list.
RSpec.describe "FR-09 FR-20 one list of what clinical advice is, for the attendant and for the check" do
  let(:prompt) { SystemPrompt.build(StoreSheet.current, CommandPhrases.current) }

  it "is the list the attendant's prompt and FR-20's check both write, one subject a line" do
    list = ClinicalAdvice.list

    expect(list.lines.size).to eq(ClinicalAdvice::SUBJECTS.size)
    expect(prompt).to include("You never give clinical advice, which is telling the visitor anything about:\n#{list}\n")
    expect(Guardrail::SYSTEM).to include("The reply gives clinical advice when it tells the visitor anything about:\n#{list}\n")
  end

  # FR-09's subjects, the three of the owner's decision of 2026-11-20 among
  # them ("a, b, c -> sim").
  it "names FR-09's subjects" do
    expect(ClinicalAdvice::SUBJECTS.join(" ")).to include(
      "dosage", "how often", "interaction", "with alcohol", "side effect", "what a medicine does to the body",
      "what a medicine is for", "how to use or store it", "suits", "a pregnancy", "a substitute", "what a symptom means",
      "a diagnosis", "what a measurement means", "blood pressure or blood glucose reading, the store's own included"
    )
  end

  it "writes no subject twice in either layer, so none is kept by hand beside the list" do
    ClinicalAdvice::SUBJECTS.each do |subject|
      expect(prompt.scan(subject).size).to eq(1), "the prompt writes #{subject.inspect} again"
      expect(Guardrail::SYSTEM.scan(subject).size).to eq(1), "the check writes #{subject.inspect} again"
    end
  end
end
