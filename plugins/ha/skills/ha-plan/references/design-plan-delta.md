# Design red-team and plan controls

## Purpose

HA catches defects as missing requirements and missing tests before implementation. Review the proposed architecture, not hypothetical code style.

## Design claims to challenge

- Each requirement has a data/control path and observable success condition.
- Failure modes have defined behavior, recovery, and user-visible outcome.
- Trust boundaries validate and authorize at the correct layer.
- Schema/API/config changes cover consumers, migration, compatibility, and rollback.
- Ordering, retries, concurrency, partial failure, and idempotency are explicit where relevant.
- Every edge case can be proven by a named test or justified non-test check.

## Convert findings into the plan

A surviving concern must become one of:

1. an approved design change;
2. an explicit success criterion;
3. a task with a RED/GREEN test;
4. a rollout/rollback/monitoring requirement;
5. a residual risk the human knowingly accepts.

Never leave a verifier concern as prose that the implementer must rediscover.

## Plan self-review

Trace every request requirement and red-team item to a task and verification command. Confirm identifiers and paths agree across the design, file map, and tasks; task dependencies form an executable order; the tree can remain green after each task; and no placeholder or silent deviation remains.
