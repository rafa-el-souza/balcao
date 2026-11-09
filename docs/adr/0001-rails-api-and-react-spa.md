# ADR-0001: Rails API with a React SPA in one repository

**Status:** accepted · **Date:** 2026-11-02

## Context

Balcão is a portfolio piece for backend roles. The author's production
experience is Ruby on Rails; the freelance market for chatbots mostly names
Python, Node and N8n. The public web app needs live updates (trace panel)
and a modest amount of UI.

## Options

1. **Rails API-only + React (Vite, TypeScript) in the same repo.** Clear
   boundary, documented HTTP contract (OpenAPI), live updates over Action
   Cable. Matches the wording of most job adverts ("Rails API + React").
2. **Rails + Inertia with React.** Less code, no separate API layer, popular
   in the recent Rails community; hides the API we want to show and is less
   recognised in adverts.
3. **Hotwire only, no React.** The Rails-native path; drops the React
   signal the author wants on the profile.
4. **Python (FastAPI) or Node.** Matches freelance adverts; leaves the
   portfolio without a public Rails piece, which is the gap identified in
   the author's portfolio review.
5. **Two repositories.** Two CIs and two deploys for one person; no benefit
   at this size.

## Decision

Option 1. Rails 8 (current stable at implementation time) as an API-only
application with the operator console as server-rendered views, and a React
+ Vite + TypeScript app under `web/` built into Rails' public directory and
served by the same process. The API contract is generated into
`docs/openapi.yaml`. RSpec over Minitest because it is what adverts and the
author's past teams used.

## Consequences

- Recruiters for Rails roles see a production-shaped Rails app with tests,
  jobs, cable, auth and deploy. Freelance clients do not care about the
  language; they see the demo.
- Two toolchains in one repo: CI runs both; the Dockerfile builds the SPA in
  a stage.
- The transport port (design §6.3) keeps the channel code out of the
  framework layer, so the architecture reads the same whatever the
  language; a Python port of the core is a possible later exercise, not a
  plan.
