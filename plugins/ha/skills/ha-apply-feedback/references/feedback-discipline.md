# Feedback evaluation discipline

Feedback is a claim to test, not an instruction to obey.

For each item:

1. Restate the technical claim without praise or dismissal.
2. Locate current code and reproduce or otherwise verify it.
3. Check whether it conflicts with the approved design or another finding.
4. Classify it as valid, already fixed, incorrect, unclear, or design-changing.
5. For valid behavior defects, capture a failing regression test before the fix.
6. Make the minimal correction and verify the exact claim plus regressions.
7. Reply with evidence; ask the human before a material design change.

Never implement a suggestion solely because it came from a reviewer. Never hide a rejected suggestion; state the code/test evidence.
