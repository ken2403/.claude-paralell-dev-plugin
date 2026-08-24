# Independent reviewer protocol

Review the immutable PR head, not the author's narrative. Start from requirements, trace changed behavior through surrounding code, and try concrete counterexamples.

## Required lenses

1. Correctness: state transitions, errors, boundaries, ordering, concurrency, and regressions.
2. Tests/compatibility: behavior-proving tests, missed call sites, schemas/APIs/config/docs, migration and rollback.
3. Security/production: trust boundaries, authorization, injection, secrets, data loss, observability, resource/performance failure.

## Finding threshold

A blocking finding needs a reproducible scenario, failing check, violated requirement, or direct path/line proof with material impact. Do not block on formatting, taste, or hypothetical misuse unsupported by the code.

The main reviewer de-duplicates and independently verifies findings. Disagreement triggers targeted evidence gathering; it is not settled by majority confidence.

## Independence

Do not expose writer self-assessments, previous verifier conclusions, or expected findings to lens reviewers. Give raw plan, PR diff/head, and lens only. Reviewers never edit or post comments.
