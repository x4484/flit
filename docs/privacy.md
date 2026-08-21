---
layout: page
title: Privacy Policy
permalink: /privacy/
---

**Effective date: August 21, 2026**

Flit is an open-source, local-first macOS mail client. This policy explains how the Flit application handles information when you connect Gmail or enable optional AI summaries.

## Information Flit accesses

With your permission, Flit uses Google's OAuth service and the `https://mail.google.com/` scope to access the Gmail features needed to synchronize message metadata, open messages, search mail, change read state, archive or trash messages, and send replies or forwarded messages.

Flit does not ask for your Google password. Google sign-in happens in your browser. Gmail refresh tokens are stored in macOS Keychain, and short-lived access tokens are held in memory.

## Local storage

Flit stores the following on your Mac:

- Account address and compact message metadata in SQLite
- Searchable sender, recipient, subject, and locally generated preview text
- A bounded cache of up to 16 Inbox message bodies, including a rolling prefetch window of 10 recent messages and recently opened messages
- Optional one-sentence AI summaries
- Pending mailbox operations needed for retry

Inbox body prefetch runs locally at low priority and does not mark messages as read, generate AI summaries, render HTML, or load remote resources. Persistent body cache files are removed when a message is archived or trashed. Bodies opened from archived search results are temporary and are removed when selection changes or at the next launch. Local data is not uploaded to a Flit-operated server because Flit does not operate a mail-storage or analytics backend.

## Network services

Flit communicates with:

- **Google Gmail and OAuth:** authentication, IMAP synchronization, search, mailbox changes, and SMTP sending
- **OpenRouter, only when you enable AI summaries:** sender, subject, and up to 24,000 readable body characters are sent using your own OpenRouter API key to generate one sentence
- **Email senders' resource hosts:** remote images, fonts, and styles load by default only when a message is selected for viewing; those requests can reveal your IP address and that the message was opened
- **Links you activate:** links open in your default external application

Flit does not sell personal information, use Gmail data for advertising, or allow humans to read Gmail data except when required to investigate a user-initiated security report and only with information the user deliberately provides. Flit's use and transfer of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including its Limited Use requirements, and is limited to providing and improving the user-facing mail features described here.

## AI summaries

AI summaries are optional. Your OpenRouter key is stored in macOS Keychain. Flit sends only the selected message's sender, subject, and bounded readable body text. The resulting sentence is cached locally and removed when the message is archived or trashed. OpenRouter's own terms and privacy policy apply to that processing.

## Analytics and diagnostics

Flit does not include advertising SDKs, behavioral analytics, or crash-reporting services. macOS may create local diagnostic reports according to your system settings.

## Retention and deletion

Gmail data remains local until you remove it, archive or trash messages under the cache rules above, or uninstall Flit and delete its application-support directory. Instructions for revoking access and deleting all local Flit data are available on the [installation page](../installation/).

## Security

Flit uses TLS for Gmail IMAP, Gmail SMTP, Google OAuth, and OpenRouter. HTML messages run in an isolated, non-persistent WebKit view with JavaScript, forms, frames, downloads, popups, and automatic navigation disabled. See the project's [security policy](https://github.com/x4484/flit/blob/main/SECURITY.md) for reporting instructions.

## Changes

Material changes will update this page and its effective date. The repository history preserves prior versions.

## Contact

For privacy questions, use [GitHub Discussions or Issues](https://github.com/x4484/flit/issues). For vulnerabilities or sensitive reports, use [GitHub private security advisories](https://github.com/x4484/flit/security/advisories/new) and do not include email content or credentials unless explicitly requested.
