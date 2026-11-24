# Kero for iPhone

A native Swift and SwiftUI client for [Kero](../README.md): the sessions your
hosts' `kerod` runs, in the same sidebar and panes as the desktop app, on an
iPhone, an iPad, or an iPhone Duo.

It has no local shell. It connects to `kerod` on the machines you add, over
the same mux protocol the desktop app uses for remote hosts.

## Connecting a host

Kero on iPhone reaches `kerod`'s own network listener, over Tailscale:

- **A computer with the Kero app.** Turn on **Settings › Hosts › Let other
  machines connect** there, and add the address it shows, such as
  `http://studio.tail1234.ts.net:7373`.
- **A server.** Add `listen = tailnet://:7373` to `~/.config/kero/config` on
  it, and add `http://devbox:7373`. To use HTTPS, serve kerod with Tailscale
  Serve (`listen = tailnet-serve://`) and add `https://devbox.tail1234.ts.net`.

Plain `http://` is only used to a Tailscale or loopback address, which
WireGuard encrypts; the app refuses it anywhere else. SSH addresses aren't
supported on iOS, since they need a bridge program on the client.

Then, in the app: **Settings › Hosts › Add Host**, type the address, and
**Test Connection**.

## What it does

- **Sidebar.** Sessions grouped by project, each project tagged with its
  host's name and color, with the desktop app's status icons: working,
  needs you, failed, exited, done.
- **Panes.** Live terminals (SwiftTerm, with JetBrains Mono and Kero's
  light and dark terminal themes), split as the session's layout says, with
  scrollback. New sessions, split panes, zoom, restart, rename, close.
- **Quick Jump.** The bolt button, or <kbd>⌘</kbd> <kbd>J</kbd> with a
  keyboard, goes to the next session that needs you, then to the next with
  something unseen.
- **Key bar.** Esc, Tab, a sticky Ctrl, arrows that repeat while held, and
  Paste.

### iPhone Duo

- Closed, the outer display shows the sidebar or the session; open, the
  inner display shows both. The terminals and their connections stay the
  same through the fold.
- A session's panes are laid out with `ArrangementView`, which puts the
  split on the fold when the device is half open, and turns a split that has
  no room along its axis.
- The key bar and toasts read the display's reserved regions
  (`reservedRegions(kind: .division / .occlusion)`), so their controls part
  around the fold and stay clear of the camera.
- Toolbar items are `Label`s with SF Symbols, so the vertical edge bar shows
  their icons. Quick Jump and New Pane have high visibility priority, and the
  rest is in the overflow menu
  (`toolbarVerticalCompressionBehavior(.prefersToolbarItems)`).
- Layout comes from size classes and geometry only, with no screen, idiom,
  or orientation checks.

## Building

You need Xcode with the iOS 27.1 SDK or later, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
ios/build-ipa.sh
```

This writes `ios/build/Kero-unsigned.ipa`, an unsigned build to sign with
your own identity when you sideload it, with AltStore, SideStore,
Sideloadly, or similar. To work on the app, run `xcodegen generate` in `ios/`
and open `Kero.xcodeproj`.

The **Build iOS IPA** workflow runs the same script on every push and
uploads the IPA as an artifact.

## Layout

| Path | What |
| --- | --- |
| `Kero/Protocol` | The wire protocol: models, the WebSocket transport, yamux, control and attach connections |
| `Kero/Model` | Saved hosts, a connection per host that reconnects on its own, and the app's state |
| `Kero/Views` | The sidebar, workspace, panes, key bar, and settings |
| `Kero/Theme` | Kero's palette and terminal themes |
| `scripts/make-appicon.swift` | Makes the app icon from `resources/icon.png` |
