# Code Quality Standards

## Contents
- How to apply
- Code smells
- Consistency checks
- Final checklist
- Detailed checklist (readability, maintainability, type safety, error handling, performance, testing, documentation)
- Naming conventions
- Anti-patterns
- Examples

## How to apply

1. **Understand existing patterns** before writing/reviewing: `Glob` for similar files
   (e.g. `**/*Service.ts`), `Grep` for usage of functions/types/patterns, `Read` key
   files to learn the established style, error-handling approach, and module structure.
2. **Evaluate** against: readability, maintainability, simplicity, error handling,
   type safety, performance, tests.
3. **Verify findings against the codebase** with `Grep` before reporting — the existing
   convention takes precedence over a general best practice.

## Code smells

- Long methods → break into smaller functions
- Deep nesting → flatten with early returns / guard clauses
- Magic numbers → named constants
- God classes → split responsibilities
- Dead code → remove (version control preserves history)

## Consistency checks

| Aspect | Check |
|--------|-------|
| Naming | Match existing variable/function naming conventions |
| Structure | Follow established file/directory organization |
| Patterns | Use same design patterns as existing code |
| Formatting | Match indentation, spacing, line breaks |
| Imports | Match import ordering and grouping |
| Error handling | Use same error handling patterns |

## Final checklist

- [ ] Logic is correct
- [ ] Edge cases handled
- [ ] Error handling appropriate
- [ ] Types are correct
- [ ] No security vulnerabilities
- [ ] Tests adequate
- [ ] Code is readable
- [ ] No unnecessary complexity
- [ ] Consistent with existing codebase style
- [ ] Follows established patterns (verified with Grep/Glob)

## Detailed checklist

### Readability
- Self-documenting through clear naming; complex logic has explanatory comments;
  consistent formatting; appropriate abstraction level; no obscure abbreviations.

### Maintainability
- Small, focused functions (single responsibility); no duplication (DRY); clear module
  boundaries; easy to modify without breaking other parts; explicit, minimal dependencies.

### Type Safety
- Public functions have type annotations; avoid `Any` unless necessary; generics properly
  constrained; return types explicit; prefer union types over overloading where apt.

### Error Handling
- Errors caught at the appropriate level; meaningful, actionable messages; no silent
  failures; graceful degradation; resources cleaned up (finally/context managers);
  custom exception types for domain errors.

### Performance
- N+1 prevention: no DB queries inside loops; eager-load related data; batch queries.
- General: no needless allocations in hot paths; appropriate data structures; cache
  expensive repeated work; async/concurrency where beneficial.

### Testing Requirements
- Unit tests for business logic; integration tests for APIs; mocks used (not overused);
  test names describe behavior; realistic data. Coverage adequacy — what counts as a
  covering test, which behavior classes need one, and when a change may ship without —
  is judged by the **test-rigor dimension**: see [test-rigor.md](test-rigor.md).

### Documentation
- Public APIs documented; complex algorithms explained; configuration options described;
  examples for non-obvious usage; CHANGELOG for user-facing changes.

## Naming conventions

| Type | Convention | Example |
|------|------------|---------|
| Classes | PascalCase | `UserAuthentication` |
| Functions | snake_case / camelCase | `get_user` / `getUser` |
| Constants | UPPER_SNAKE | `MAX_RETRIES` |
| Private | Leading underscore | `_internal_method` |
| Boolean vars | is/has/can prefix | `is_active`, `has_permission` |
| Collections | Plural names | `users`, `items` |

## Anti-patterns

- **Premature abstraction**: don't abstract until 3+ concrete use cases; three similar
  lines beat a premature abstraction.
- **Over-engineering**: no configurability you don't need yet; don't design for
  hypothetical futures (YAGNI).
- **Shotgun surgery**: if one change requires edits across many unrelated files, consider
  consolidating; related logic should be co-located.
- **Feature envy**: a method using more of another class's data than its own should move
  to that class.

## Examples

### Early return for deep nesting
```python
# Bad - deep nesting
def process(data):
    if data:
        if data.is_valid():
            if data.has_permission():
                return do_work(data)

# Good - guard clauses
def process(data):
    if not data:
        return None
    if not data.is_valid():
        raise ValueError("Invalid data")
    if not data.has_permission():
        raise PermissionError("Access denied")
    return do_work(data)
```

### N+1 query
```python
# Bad - N+1
for user in users:
    posts = db.query(Post).filter(Post.user_id == user.id).all()

# Good - eager loading
users = db.query(User).options(joinedload(User.posts)).all()
```
