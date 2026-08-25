# Codebase Consistency (beyond the diff)

A senior reviewer holds the whole codebase in their head: reading a diff, they instantly
know which other files should also change. This replicates that by building context around
the diff and checking for missed propagation, stale references, and cross-layer drift.
The value scales with PR size and cross-cutting concerns.

## Contents
- Workflow
- Build codebase context
- Trace change propagation
- Cross-layer consistency
- Findings format
- Propagation paths by change type

## Workflow

```
- [ ] Step 1: Build codebase context (usage graph vs diff file list)
- [ ] Step 2: Run local build / lint / typecheck
- [ ] Step 3: Trace change propagation
- [ ] Step 4: Check related files outside the diff
- [ ] Step 5: Verify cross-layer consistency
- [ ] Step 6: Compile findings
```

## Build codebase context

1. Read the PR/plan **intent** — what is it trying to accomplish?
2. Extract **changed entities** from the diff: renamed identifiers, modified
   types/interfaces, altered DB schemas, changed API contracts, modified configs.
3. For each, use `Grep`/`Glob` to map its **usage graph** — every file that imports,
   references, extends, or depends on it.
4. Compare the usage graph to the diff's file list. Files in the graph but **not** in the
   diff are candidates for missed changes. (This is the most critical step.)

Run the project's build/lint/typecheck for a mechanical safety net (detect commands from
Makefile, package.json, pyproject.toml, Cargo.toml, go.mod, etc.); categorize errors.

## Trace change propagation

- **Data model changes** → query code, serializers, API responses, form fields, test
  fixtures, mock/seed data
- **API contract changes** → frontend components, integration tests, API clients, docs
- **Schema/migration changes** → list migrations in execution order; no migration running
  AFTER a rename/drop may reference old names; check migrations added on base since branch
- **Type/interface changes** → implementations, callers, type assertions, casts
- **Configuration changes** → all readers of the config, environment-specific configs

## Cross-layer consistency

- **DB ↔ ORM/model**: schema changes reflected in models, relation names, queries
- **Backend ↔ API contract**: changed types/routes reflected in specs, response shapes
- **API contract ↔ Frontend**: changed responses reflected in FE types, form fields, display
- **Code ↔ Tests**: changed behavior reflected in unit/integration/E2E tests, mocks/fixtures
- **Code ↔ Config**: changed features reflected in config files, permissions, feature flags

Also flag **partial updates**: a variable renamed but string literals / form-field
references using the old name left behind.

## Findings format

```
PR_INTENT: [one-line summary]
CHANGED_ENTITIES: [entities modified by the diff]
BUILD_ERRORS: [categorized list or "none"]
MISSED_FILES: [file:line with what needs updating, or "none"]
PARTIAL_UPDATES: [file:line with what was missed, or "none"]
CROSS_LAYER_ISSUES: [list or "none"]
MIGRATION_ORDERING: [conflicts or "none"]
```

Per finding: **Severity** (Critical/High/Medium/Low), **Location** (file:line),
**Issue**, **Suggestion**.

## Propagation paths by change type

### Entity rename/remove
- All source files importing/referencing the entity
- All test files referencing it
- All mock, fixture, and seed data using it
- All string literals containing the name (form fields, error/log messages, API paths, query params)
- All ORM/DB relation and association names
- All generated type field names derived from the entity
- All config and environment-variable references
- All E2E test data and selectors

### Schema/migration change
- Migration execution order: nothing running after a rename/drop references old names
- Migrations added on base since the PR branched do not conflict
- Schema definition files consistent with migration changes
- Generated code regenerated after schema changes
- DB policies, constraints, and indexes recreated for renamed entities

### API contract change
- All callers updated to new request/response shape and route paths
- API docs/spec files updated
- Frontend types and data-fetching code updated
- Integration and E2E tests updated

### Type/interface change
- All implementations updated
- All callers passing/receiving the type updated
- All type assertions and casts updated

### Configuration change
- All files reading the configuration updated
- All environment-specific config files updated
- Deployment and CI/CD configurations updated
