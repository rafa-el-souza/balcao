# ADR-0009: No retrieval-augmented generation in V1

**Status:** accepted · **Date:** 2026-11-02

## Context

Most chatbot portfolios bolt on a vector database and call it RAG. Balcão's
knowledge is small and structured: a store fact sheet (hours, address,
delivery areas, payment, services; a few thousand tokens) and a catalogue
of a few hundred products with name, brand, active ingredient, price, stock
and a prescription flag. The one large corpus in a pharmacy, package
inserts (bulas), is exactly what the clinical boundary (FR-09) forbids the
attendant to use.

## Options

1. **Vector RAG** (embeddings, pgvector or a hosted store) over the fact
   sheet and catalogue. Adds an embeddings vendor (Anthropic does not sell
   embeddings), an indexing pipeline, a second thing to keep in sync, and
   latency, to retrieve what already fits in the prompt or in one SQL query.
2. **Fact sheet in the cached system prompt; catalogue through a tool using
   Postgres trigram similarity and full-text search; the model normalises
   the query (brand or colloquial name → active ingredient) before calling
   the tool.** Handles typos and synonyms, zero new vendors, one source of
   truth, visible in the glass box as one tool call.
3. **Hybrid**: option 2 plus embeddings only for the catalogue. Same cost as
   1 for a marginal gain on a few hundred rows.

## Decision

Option 2, with one refinement decided with the evals: the cached prompt
holds only identity, opening hours and policy; the rest of the store sheet
(delivery, payment, services, contact, parking) is reached through
`get_store_info(topic)`, so the glass box shows a tool call and the prompt
stays small. The `search_products` tool runs `pg_trgm` similarity on name,
brand and active ingredient plus a full-text match, returns the top five
with scores, and the prompt tells the model to normalise the query first
("remédio pra dor de cabeça" → the ingredient it means) and to say "not
found" rather than invent. The eval suite covers typos and colloquial
names.

## Consequences

- One fewer vendor, one fewer pipeline, nothing to re-index.
- If the catalogue grows to thousands of rows with long descriptions, or a
  non-clinical corpus appears (delivery policies per neighbourhood, a FAQ of
  hundreds of entries), revisit with a hybrid search ADR.
- The README states this decision plainly; it is a point in the
  engineering section, not an omission.
