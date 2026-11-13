# Tools that exist only in the suite, to drive AgentRunner and AgentTool
# without the pharmacy's tools (those arrive with their own slices).
module SpecTools
  class EchoInput < Anthropic::BaseModel
    required :text, String, doc: "the text to echo"
  end

  # Answers with the text it was given and the turn the runner gave it.
  class Echo < AgentTool
    doc "Echoes the text back."
    input_schema EchoInput

    def perform(input) = { "echo" => input.text, "turn_id" => turn.id }
  end

  # Reserves two units of the product whose SKU it is given, keyed by the turn
  # as create_reservation will be (NFR-02), for the job's specs before PR-13.
  class Reserve < AgentTool
    doc "Reserves two units."
    input_schema EchoInput

    def perform(input)
      product = Product.find_by!(sku: input.text)
      reservation = Reservation.create_once!(turn:, product:, quantity: 2, pickup_until: 1.day.from_now.end_of_day)
      { "code" => reservation.code }
    end
  end

  # Fails the way a tool refuses on purpose: its message is for the model.
  class Refuse < AgentTool
    doc "Always refuses."
    input_schema EchoInput

    def perform(_input) = raise(AgentTool::Error.new("no such topic", reason: "unknown_topic"))
  end

  # Fails the way a bug does: its message is not for the model.
  class Crash < AgentTool
    doc "Always crashes."
    input_schema EchoInput

    def perform(_input) = raise("PG::ConnectionBad: secret host 10.0.0.5")
  end
end
