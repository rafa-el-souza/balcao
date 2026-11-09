# ADR-0005: Voice note transcription through a hosted speech-to-text API, behind a port

**Status:** accepted · **Date:** 2026-11-02 (proposed in the morning, decided the same day)

## Context

Voice notes are a common client request on WhatsApp (FR-11). The Claude
Messages API does not accept audio input, so transcription is a separate
service. Notes are short (under 60 s), in Portuguese, English or Spanish.
The VM is small (2 vCPU, 4 GB) and already runs the web process, the
worker and Postgres.

## Options

1. **Hosted speech-to-text API** (a Whisper-compatible endpoint from a
   major provider, or a cloud speech service). Pennies per minute, good
   quality in the three languages, one more vendor key, audio leaves the
   host for the duration of the call.
2. **Self-hosted Whisper-family model in a sidecar container.** No vendor;
   adds a Python container and about 1 GB of RAM to a 4 GB VM, days of
   work and a new failure mode, for a property ("audio never leaves the
   host") that neither audience of this project values.
3. **No voice in V1.** Drops a feature clients ask for.

## Decision

Option 1, only. A `Transcriber` port with two adapters: the hosted API and
a null adapter for tests. The audio file is deleted after transcription;
only the text is stored, marked `source: audio`; the vendor is named in the
privacy notice. Provider chosen at M4 by a 30-minute comparison of two
candidates on ten real notes in the three languages (accuracy, latency,
price); the result is recorded as a short ADR-0014 at M4 (the first
milestone after the MVP, design §9.2) and this ADR's status line points to it.

## Consequences

- Nothing to operate beyond a key and a spend alert at the vendor.
- The port keeps the option of a self-hosted adapter open at no cost; it is
  not planned.
- Transcription cost is metered into the budget ledger like model usage
  (FR-14).
