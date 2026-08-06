# Attribution

Third-party work this project builds on. See [README.md](README.md) for the project
itself, and [LICENSE](LICENSE) for its own terms.

## Launcher icon

The sparkle in the app icon is derived from **"AI"** by [Icons8](https://icons8.com),
used under the [Icons8 free licence](https://icons8.com/license), which permits use with
a link back to icons8.com.

- Source art: `assets/dpad-chat-icon.png`, downloaded from Icons8 as `icons8-ai-240.png`
- Derived work: `app/res/icon.png`, produced by `tools/make_icon.py`

The derivation keeps only the alpha channel of the original and recolours it, because the
source is solid black and would be very nearly invisible against Onion's dark themes. It
is then composited onto a rounded slate tile.

The source art is kept in `assets/` rather than `app/res/` so that only the generated
icon ships in the release archive.

## CA certificates

`app/res/cacert.pem` is the Mozilla CA certificate store as distributed by the
[curl project](https://curl.se/docs/caextract.html), which places it in the public
domain. Refresh it with `make cacert`; the recorded checksum is in
`app/res/cacert.sha256`.

## Onion OS

This app targets [Onion OS](https://github.com/OnionUI/Onion) and runs inside its
bundled `st` terminal, which supplies the on-screen keyboard. Onion is not vendored here;
the app only calls binaries already present on the device.
