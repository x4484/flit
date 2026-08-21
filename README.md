<p align="center">
  <img src="assets/FLIT-logo.png" alt="Flit" width="420">
</p>

<p align="center">
  <a href="https://flit-pied.vercel.app/">Website</a> ·
  <a href="https://github.com/x4484/flit/releases">Downloads</a> ·
  <a href="https://flit-pied.vercel.app/privacy/">Privacy</a>
</p>

Flit is an experimental, extremely lightweight native macOS mail client focused on one job: triaging mail quickly across accounts.

> **Status:** public beta candidate. Signed downloads are awaiting Apple Developer ID/notarization credentials and Google OAuth production approval. Do not publish the unsigned validation package. The local-first AppKit interface, SQLite store, local header search, Gmail OAuth, bounded periodic Gmail metadata sync, lazy Gmail thread navigation, rolling Inbox body prefetch, full-fidelity HTML rendering, cached OpenRouter summaries, optimistic remote actions, and Gmail reply/forward sending are working. iCloud remains under development.

## Principles

- Native AppKit shell, with an isolated WebKit view only for sender-authored HTML email
- Show the local inbox before touching the network
- Keep memory proportional to the visible viewport
- Prefetch a bounded rolling Inbox window while keeping only the active message in WebKit
- Delete persistent cached bodies after archive; treat searched archived bodies as selection-scoped temporary files
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

## Install

Signed and notarized universal downloads will appear on [GitHub Releases](https://github.com/x4484/flit/releases) after the public OAuth consent screen is approved. Flit requires macOS 13 or newer and supports Apple silicon and Intel Macs.

See the [installation guide](https://flit-pied.vercel.app/installation/) for release installation and data-removal instructions.

## Build from source

Requirements:

- macOS 13 or newer
- Swift 5.10 or newer through Xcode or Command Line Tools

```bash
swift run Flit
```

The initial build opens the local inbox immediately. Use **Accounts → Add Gmail Account…** after completing the [local Google OAuth setup](docs/google-oauth-setup.md). Flit then authenticates with XOAUTH2 and synchronizes Gmail inbox headers in bounded batches.

To populate local demo data:

```bash
FLIT_SEED_DEMO=1 swift run Flit
```

Build an ad-hoc signed app bundle:

```bash
make app
open dist/Flit.app
```

Build a universal Apple silicon + Intel app:

```bash
make app-universal
```

Public release packaging is defined in `scripts/package-release.sh` and `.github/workflows/release.yml`. It refuses to create a publishable package without the approved OAuth configuration, a Developer ID Application identity, and notarization credentials. See the [release checklist](docs/release-checklist.md).

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

GmailSyncService
   ├── TLS IMAP + XOAUTH2 metadata sync
   ├── bounded initial, incremental, and 60-second foreground metadata sync
   ├── remote read/archive/trash/deletion reconciliation
   ├── bounded Gmail X-GM-THRID discovery from All Mail
   ├── demand-prioritized 1 MiB body fetch + ten-message prefetch window + 16-file cache
   ├── queued read, archive, and trash replication
   └── TLS SMTP + XOAUTH2 reply, reply-all, and forward

OpenRouterSummaryService
   └── one-sentence Ling 3.0 Flash summaries cached in SQLite

SyncCoordinator
   └── cross-account connection budget
```

The unified inbox is a keyset-paginated SQLite query. While Flit is running, Gmail metadata synchronizes every 60 seconds, preserving the selected message and refreshing its open thread. After metadata appears, Flit fills a rolling ten-message Inbox body window at low priority; a selected uncached message always takes priority, and only the active body enters the single reader WebView. After Flit sends a reply, bounded follow-up metadata checks add the sent message to that thread as soon as Gmail exposes it. Selecting a Gmail conversation lazily discovers up to 50 thread headers from All Mail and presents them as selectable native rows beneath Summary. Archive and trash remove a row immediately, then persist a pending remote operation. Search covers inbox and archived headers through FTS5. Cached body files are deleted when a message leaves the inbox.

See [the interface direction](docs/interface-direction.md) for the native design principles and reference notes guiding the UI.

## Roadmap

- [x] Native AppKit unified-inbox shell
- [x] SQLite metadata store and FTS5 header search
- [x] Optimistic archive/trash queue
- [x] Bounded, paginated inbox reads
- [x] Gmail OAuth/XOAUTH2 account setup
- [x] Streaming IMAP transport and bounded incremental UID sync
- [x] Replicate queued Gmail archive, trash, and read operations
- [x] Reconcile remote Gmail moves, deletions, and read-state changes
- [x] Load older Gmail inbox pages and search unsynchronized inbox and archived headers
- [x] Lazy Gmail thread discovery and right-pane message navigation
- [x] Periodic metadata-only sync with selection-preserving thread refresh
- [x] Local thread snippets generated after selected-body reads
- [x] Rolling ten-message Inbox body prefetch with a bounded LRU cache
- [x] Gmail SMTP reply, reply-all, and forward
- [x] Cached one-sentence OpenRouter summaries
- [ ] iCloud app-specific-password setup
- [ ] Offline SMTP outbox and retry queue
- [ ] Release-build performance harness with a million-message fixture

## Non-goals

Flit does not plan to support calendars, contacts, rules, rich-text composition, plugins, or general-purpose browsing inside the app.

## License

MIT
