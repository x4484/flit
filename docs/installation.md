---
layout: page
title: Installation
permalink: /installation/
---

## Requirements

- macOS 13 Ventura or newer
- Apple silicon or Intel Mac
- A Gmail account

## Install Flit

1. Download the latest `Flit-*.dmg` from [GitHub Releases](https://github.com/x4484/flit/releases).
2. Open the disk image.
3. Drag **Flit** into **Applications**.
4. Open Flit from Applications.
5. Choose **Accounts → Add Gmail Account…** and complete Google sign-in in your browser.

Public builds are signed with a Developer ID certificate and notarized by Apple. You should not need to bypass Gatekeeper. If macOS says that the app cannot be verified, do not override the warning; confirm that you downloaded the DMG from the official GitHub repository and report the problem through [support](../support/).

## Verify the download

Each release includes `SHA256SUMS`. In Terminal:

```bash
shasum -a 256 -c SHA256SUMS
```

The line for the downloaded DMG should report `OK`.

## Uninstall and delete local data

1. Quit Flit.
2. Revoke Flit's access from your [Google Account connections](https://myaccount.google.com/connections).
3. Move Flit from Applications to Trash.
4. Delete `~/Library/Application Support/Flit` to remove local headers, summaries, and cached bodies.
5. In **Keychain Access**, delete items whose service is `com.ranihaddad.flit.oauth` or `com.ranihaddad.flit.openrouter`.

This removes Flit's local data. It does not delete messages stored by Gmail.
