# One span of a turn's trace, in the shape of OpenTelemetry (ADR-0010).
class TraceEvent < ApplicationRecord
  TRACE_ID = /\A\h{32}\z/
  SPAN_ID = /\A\h{16}\z/
  LOWERCASE = /\A[^A-F]*\z/

  belongs_to :turn

  validates :trace_id, format: { with: TRACE_ID }
  validates :span_id, format: { with: SPAN_ID }
  validates :parent_span_id, format: { with: SPAN_ID }, allow_nil: true
  validates :trace_id, :span_id, :parent_span_id, format: { with: LOWERCASE }, allow_nil: true
  validates :name, :started_at, presence: true
end
