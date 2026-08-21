# Contributing

Flit is deliberately narrow. Changes should preserve its bounded-memory, local-first design.

## Before submitting a change

```bash
swift build -c release
swift test
```

For performance-sensitive work, profile a release build and include the before/after measurement. Avoid adding dependencies unless they replace substantially more code and have a measured runtime cost.

## Design constraints

- No synchronous network, database, MIME, or file work on the main actor
- No collection proportional to total mailbox size in application memory
- No automatic attachment download
- Keep WebKit isolated to sender-authored HTML email, with active content disabled
- No full table reload for a single-message mutation
