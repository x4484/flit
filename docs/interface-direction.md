# Interface direction

Flit's interface should make triage feel quiet, immediate, and finite. It uses native AppKit and borrows interaction principles—not code or assets—from [Writer](https://github.com/joelbqz/writer-computer), a GPL-3.0 local-first Markdown editor.

## Reference observations

Writer succeeds through restraint:

- The titlebar and app content read as one continuous surface.
- A narrow, search-first sidebar holds dense navigation without looking crowded.
- Selected rows use quiet rounded neutral fills instead of a loud accent color.
- The primary content has a capped reading width and generous margins.
- Metadata sits at the edges and stays visually subordinate.
- Chrome is compact, controls are contextual, and repeated actions are keyboard-accessible.
- One accent color carries meaning while surfaces remain neutral.
- Separators are rare; spacing and surface contrast establish structure.

## Flit adaptation

| Reference principle | Native Flit adaptation |
| --- | --- |
| Integrated window chrome | Transparent native titlebar with content extending beneath it |
| Search-first sidebar | Persistent native search field above the unified inbox |
| Quiet active state | Custom `NSTableRowView` with a rounded neutral selection fill |
| Focused writing canvas | Message reader capped near 734 pt and centered in the available pane |
| Restrained controls | Borderless SF Symbol archive and trash actions with tooltips and accessible names |
| Keyboard-first workflow | Command menu equivalents and automatic selection of the next message |
| Calm hierarchy | System typography, semantic colors, fixed row height, and no decorative animation |

## Deliberate differences

Flit should not visually clone Writer or inherit its implementation:

- No GPL source or assets are copied into this MIT repository.
- No Tauri, React, WebKit, backdrop blur, custom theme engine, or command palette.
- No tabs: message triage benefits from one stable reader context.
- No persistent body statistics or footer chrome.
- Use the system accent by default rather than adopting Writer's orange identity.
- Prefer native semantic colors so light, dark, increased-contrast, and accessibility settings remain coherent.

## Interaction standard

The high-frequency loop is intentionally plain:

1. Selection changes immediately.
2. The next body is prepared in the background.
3. Archive or Trash removes the row without animation.
4. The next row becomes active in the same interaction.
5. Remote confirmation happens after the local transition.

Every visual refinement must preserve the memory and responsiveness budgets in `README.md`.
