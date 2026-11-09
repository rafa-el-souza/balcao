# ADR-0010: Trace recorder shaped after OpenTelemetry; SDK adoption deferred

**Status:** accepted · **Date:** 2026-11-02

## Context

The glass box (FR-12) needs a recorder that every producer in the turn
pipeline writes to: inbound, model calls, tool calls, guardrail check,
outbound, channel delivery. OpenTelemetry would make it an industry-standard
trace with free spans from Rails (HTTP, jobs, SQL) and exportability to any
backend, at the cost of one to two extra days in the MVP and the risk of it
spending its time on an exporter instead of on the conversation. The
visitor sees no difference either way.

## Options

1. **OpenTelemetry SDK from day one** with an in-process exporter to
   Postgres and Action Cable.
2. **Hand-rolled event log**: a flat list of events with free-form payloads.
   Cheapest today; migrating to OpenTelemetry later rewrites the panel.
3. **Hand-rolled recorder with the shape of OpenTelemetry**: spans with
   start, end, parent and attributes; attribute names from the GenAI
   semantic conventions; trace and span ids in OpenTelemetry format; one
   `TraceRecorder` interface. The SDK and exporter replace the recorder's
   internals later, with the panel unchanged.

## Decision

Option 3. Concretely:

- `TraceRecorder#start_span(name, parent:, attributes:)` returns a span;
  `span.finish(attributes:)` closes it. The turn is the root span; model
  call, tool call, guardrail, outbound and delivery are children.
- Attribute names follow the OpenTelemetry GenAI semantic conventions for
  model calls (request model, input/output/cached token counts, finish
  reason, and so on) and plain names for the rest; cost in USD and BRL is
  our own attribute, named with a `balcao.` prefix.
- Trace id 128-bit and span id 64-bit, lowercase hex, generated as
  OpenTelemetry does; `conversation.trace_token` is independent of them.
- Storage: `trace_events` holds spans (one row per span, closed on finish)
  and broadcasts twice, on start and on finish, so the panel can show
  "model call started" while the call runs (FR-12); the panel renders the
  span tree.
- The system prompt is recorded as a summary attribute only (threat model
  SR-12).

Adopting the OpenTelemetry SDK is a later, low-priority task: wire the
`TraceRecorder` onto the SDK's tracer, add an in-process exporter to the
same table, enable the Rails instrumentation for HTTP, ActiveJob and SQL
with a filter that keeps SQL spans out of the panel. Estimated one to two
days; no panel change.

## Consequences

- The MVP keeps its scope; nothing to debug but our own small class.
- The migration cost is bounded because the data shape does not change.
- Until the migration, the README does not claim OpenTelemetry; it says the
  trace follows its conventions.
