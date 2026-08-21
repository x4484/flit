# Flit

Flit is an experimental, extremely lightweight native macOS mail client focused on one job: triaging mail quickly across accounts.

> **Status:** early scaffold. The local-first AppKit interface, SQLite store, archive queue, and local header search are working. Gmail and iCloud transport are not implemented yet.

## Principles

- Native AppKit, not Electron or a web view
- Show the local inbox before touching the network
- Keep memory proportional to the visible viewport
- Download message bodies only when opened
- Delete cached bodies after archive; retain compact searchable headers
- Apply archive, trash, and read actions optimistically
- Keep the main thread free of SQL, MIME, file, and network work

## Current performance budgets

| Metric | Budget |
| --- | ---: |
| Idle memory | <60 MB |
| Normal triage memory | <90 MB |
| Warm launch to inbox | <100 ms |
| Archive visual response | <16 ms |
| Local search first results | <50 ms |

These are targets, not yet published benchmark results.

## Run

Requirements:

- macOS 13 or newer
- Swift 5.10 or newer through Xcode or Command Line Tools

```bash
swift run Flit
```

The initial build has no account setup yet, so it opens an empty inbox. To populate local demo data:

```bash
FLIT_SEED_DEMO=1 swift run Flit
```

Build an ad-hoc signed app bundle:

```bash
make app
open dist/Flit.app
```

Run tests:

```bash
swift test
```

## Architecture

```text
AppKit UI
   │ paged value types + optimistic commands
   ▼
MailStore actor ── SQLite WAL + FTS5
   │
   ├── pending operation queue
   └── bounded body-file cache

SyncCoordinator
   ├── Gmail IMAP/XOAUTH2 + SMTP (planned)
   └── iCloud IMAP + SMTP (planned)
```

The unified inbox is a keyset-paginated SQLite query. Archive and trash remove a row immediately, then persist a pending remote operation. Search covers inbox and archived headers through FTS5. Cached body files are deleted when a message leaves the inbox.

See [the interface direction](docs/interface-direction.md) for the native design principles and reference notes guiding the UI.

## Roadmap

- [x] Native AppKit unified-inbox shell
- [x] SQLite metadata store and FTS5 header search
- [x] Optimistic archive/trash queue
- [x] Bounded, paginated inbox reads
- [ ] Gmail OAuth/XOAUTH2 account setup
- [ ] Streaming IMAP transport and incremental sync
- [ ] iCloud app-specific-password setup
- [ ] Plain-text MIME body selection and bounded cache
- [ ] SMTP outbox
- [ ] Release-build performance harness with a million-message fixture

## Non-goals

Flit does not plan to support calendars, contacts, rules, rich-text composition, remote images, plugins, or an embedded browser-based mail renderer.

## License

MIT
