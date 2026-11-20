# FR-09 and FR-20: what clinical advice is, written once. The attendant's
# prompt (SystemPrompt) and FR-20's check (Guardrail::SYSTEM) both list these
# subjects from here, so the two layers of the boundary cannot drift apart:
# the norms study of 2026-11-20 found the check counting what a medicine does
# to the body while the prompt did not name it, and the owner pointed at the
# two lists kept by hand (design §10, M2-4b). Each layer keeps its own framing
# and rules around the list: the attendant's emergencies, the animal's
# veterinarian and the check's exemptions are not here.
module ClinicalAdvice
  SUBJECTS = [
    "the dosage of a medicine, or how much of it to take or give",
    "how often or for how long to take it",
    "an interaction with another medicine, with alcohol or with food",
    "a side effect, or what a medicine does to the body",
    "what a medicine is for, or how to use or store it",
    "whether a medicine suits a person, an age, a pregnancy, a condition or a symptom",
    "a medicine to take as a substitute for another",
    "what a symptom means, or what the visitor or someone else may have (a diagnosis)",
    "what a measurement means, such as a blood pressure or blood glucose reading, the store's own included"
  ].freeze

  # The subjects one a line, as both prompts write them.
  def self.list = SUBJECTS.map.with_index { |subject, index| "- #{subject}#{index == SUBJECTS.size - 1 ? "." : ";"}" }.join("\n")
end
