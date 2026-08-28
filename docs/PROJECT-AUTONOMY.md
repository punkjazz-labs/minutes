---
project: minutes
updated: 2026-08-04
kind: manual
default_tier: T1
gates:
  publish: ask
  merge_main: ask-per-session
  spend: ask
  secrets: ask
  deploy: ask
  branch_work: autonomous
protected_paths:
  - .github/
  - docs/PROJECT-AUTONOMY.md
  - scripts/audit/
  - scripts/precheck*
  - scripts/verify*
  - tests/
  - playwright.config.*
  - vitest.config.*
  - pytest.ini
  - pyproject.toml
  - package.json
  - package-lock.json
  - pnpm-lock.yaml
  - yarn.lock
  - .pre-commit-config.yaml
  - .husky/
never_upstream_paths:
  - .hermes-fr.yaml
  - .hermes-autoship.json
probation: none
active_policies: []
negative_memory: []
project_skill: none
---
# Start Here
Current state: Public repository at v0.3. The app ships as a signed and notarised disk image on GitHub releases. The basement console links the latest release.
Standing orders: Work on feature branches; keep documentation and tests current; proceed autonomously within the gates above.
Escalation extras: none
Verification: generic checklist only
Read before any task: this file, AGENTS.md, active global policies, and relevant negative memory.
