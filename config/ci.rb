# Run using bin/ci: the same set as .github/workflows/ci.yml, locally.

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: RuboCop", "bin/rubocop"
  step "Security: bundler-audit", "bin/bundler-audit"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager -w2 --exit-on-warn --exit-on-error"
  step "Tests: RSpec", "env COVERAGE=1 bundle exec rspec"
  step "Tests: the fast evals, recorded", "bin/evals --recorded"

  step "Security: npm audit, runtime tree", "npm --prefix web audit --omit=dev --omit=optional --audit-level=high"
  step "Style: ESLint", "npm --prefix web run lint"
  step "Style: Prettier", "npm --prefix web run format:check"
  step "Types: TypeScript", "npm --prefix web run typecheck"
  step "Tests: Vitest", "npm --prefix web test"
  step "Build: web", "npm --prefix web run build"
  step "Tests: NFR-10's gate", "npm --prefix web run e2e"

  step "Lint: GitHub Actions", "bin/actionlint"
  step "Security: gitleaks", "gitleaks git --redact --no-banner"
end
