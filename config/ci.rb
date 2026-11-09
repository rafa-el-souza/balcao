# Run using bin/ci: the same set as .github/workflows/ci.yml, locally.

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: RuboCop", "bin/rubocop"
  step "Security: bundler-audit", "bin/bundler-audit check --update"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager -w2 --exit-on-warn --exit-on-error"
  step "Tests: RSpec", "bundle exec rspec"

  step "Security: npm audit, runtime tree", "npm --prefix web audit --omit=dev --audit-level=high"
  step "Style: ESLint", "npm --prefix web run lint"
  step "Style: Prettier", "npm --prefix web run format:check"
  step "Types: TypeScript", "npm --prefix web run typecheck"
  step "Tests: Vitest", "npm --prefix web test"
  step "Build: web", "npm --prefix web run build"

  step "Security: gitleaks", "gitleaks git --redact --no-banner"
end
