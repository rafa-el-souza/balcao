# The attendant's tools (design §6.6), each an AgentTool: the model asks for
# them by name and the SDK's tool runner calls them with the turn the runner
# gave them (SR-16). The names are part of the evals (evals/cases.yaml). The
# rest of §6.6's list arrives with its slice: list_slots and book_appointment
# with FR-08, request_human at M2.
module Tools
  ALL = [ GetStoreInfo, SearchProducts, CreateReservation ].freeze
end
