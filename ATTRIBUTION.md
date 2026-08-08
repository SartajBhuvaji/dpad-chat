# Attribution

Third-party work this project builds on. See [README.md](README.md) for the project
itself, and [LICENSE](LICENSE) for its own terms.

## Launcher icon

Original artwork by the project author, under this project's own [LICENSE](LICENSE). No
third-party asset is involved, so nothing here is owed to anyone else.

- Source art: `assets/dpad-chat-icon.png`
- Derived work: `app/res/icon.png`, produced by `tools/make_icon.py`

The derivation trims the transparent border off the source, squares the crop, and scales
it to 74x74 with a margin of 6% — the size and framing Onion's own app icons use, measured
off them rather than documented anywhere.

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
