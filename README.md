# MemTicker

A tiny macOS menu bar app that shows how much RAM you're using, right next to the
clock and battery.

```
12.50 / 16 GB
```

That's it. No window, no Dock icon, no preferences pane. The number matches
Activity Monitor's **Memory Used**, updated every couple of seconds.

## Install

Grab `MemTicker.dmg` from the [latest release](../../releases/latest), open it,
and drag MemTicker into Applications.

**First launch will be blocked.** The app isn't notarized by Apple, so Gatekeeper
stops it. Right-click MemTicker in Applications, choose **Open**, and confirm in
the dialog. macOS remembers the choice, so this is a one-time thing.

If you'd rather do it from the terminal:

```sh
xattr -dr com.apple.quarantine /Applications/MemTicker.app
open /Applications/MemTicker.app
```

Nothing appears on screen — look at your menu bar.

## Using it

Click the number for a breakdown and a few options:

- **App Memory / Wired / Compressed / Cached Files** — the same four rows
  Activity Monitor shows at the bottom of its Memory tab.
- **Display** — switch between `12.50 / 16 GB`, `12.50 GB`, and `78%`.
- **Refresh Every** — 1, 2, 5, or 10 seconds. Default is 2.
- **Start at Login** — works once the app is in `/Applications`.
- **Quit MemTicker**.

Command-drag the item to move it along the menu bar. It can't be placed to the
right of Apple's own icons; macOS reserves that side.

## Building from source

You need the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is
not required — there's no project file, just one Swift source file and a shell
script.

```sh
git clone https://github.com/dynamic-auto/MemTicker.git
cd MemTicker
./build.sh
open build/MemTicker.dmg
```

The script compiles for arm64 and x86_64, `lipo`s them into a universal binary,
assembles the `.app` bundle, ad-hoc signs it, and wraps it in a disk image with
an Applications symlink for drag-installing.

## Releasing

Push a tag and GitHub Actions builds the DMG on a macOS runner and attaches it to
a new release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The version string in `Info.plist` is derived from the tag, so `v1.0.0` becomes
`1.0.0`. Ordinary pushes to `main` still build and upload the DMG as a workflow
artifact, they just don't create a release.

## How the number is calculated

MemTicker reads `host_statistics64(HOST_VM_INFO64)` and applies Activity
Monitor's definition:

```
Memory Used = App Memory + Wired + Compressed
```

where App Memory is `internal_page_count - purgeable_count`, Wired is
`wire_count`, and Compressed is `compressor_page_count`, each multiplied by the
kernel page size. Cached Files (`external_page_count`) are deliberately excluded,
because macOS will hand that memory back the moment something needs it.

A common mistake is to use `active + wired` pages instead, which overstates usage
by a wide margin on modern macOS. Total physical RAM comes from
`ProcessInfo.physicalMemory` (i.e. `hw.memsize`), and GB means 1024³ so a 16 GiB
machine reads as a clean `16`.

Expect agreement with Activity Monitor to within a few hundred MB. The two
sample at different instants and the kernel's accounting moves constantly.

## Requirements

macOS 12 Monterey or later. Apple Silicon and Intel both supported.

The "Start at Login" toggle uses `SMAppService`, which needs macOS 13; on
Monterey that menu item simply doesn't appear.

## Notarizing your own builds

If you want to distribute this without the Gatekeeper warning, you need a paid
Apple Developer account. Replace the ad-hoc `codesign --sign -` line in
`build.sh` with your Developer ID Application certificate, add
`--options runtime`, then submit the DMG with `xcrun notarytool submit` and
staple the ticket. That's beyond what this repo does by default, on purpose —
ad-hoc signing keeps it buildable by anyone with zero setup.

## License

MIT. See [LICENSE](LICENSE).
