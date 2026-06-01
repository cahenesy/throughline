---
name: Reviewer finding seems wrong
about: The review gate (or design-critique gate) raised a finding you believe is incorrect
title: "[finding] "
labels: reviewer-finding
assignees: ''
---

## The finding

Paste the `STEP_REVIEW: BLOCK ...` / `REVIEW_RESULT: BLOCK ...` /
`DESIGN_REVIEW: BLOCK ...` line verbatim:

```
(paste here)
```

## Why you believe it's wrong

<!-- The strongest version of this is a counter-example: code, a test, or a
     spec citation that contradicts the finding. "It seems too strict" is
     hard to act on; "the guard it demands already exists at line N" is easy. -->

## The code it was raised against

The diff range or file/lines the finding cites (sanitized as needed):

```
(paste here)
```

## What happened next

- [ ] The bounded rework loop "fixed" something that wasn't broken
- [ ] The build halted (rework-budget-exhausted / structural-finding)
- [ ] I worked around it manually
- [ ] Other:

## Environment

- throughline version:
- Review model (default sonnet, or overridden):
