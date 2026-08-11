# ExtendCast for macOS

The macOS application contains sender and receiver modes in one Swift package.

```bash
cd macOS
swift test
./build.sh
```

`build.sh` produces a signed Universal 2 application and ZIP in this directory.
The default build uses the project's stable Apple Development identity so
macOS privacy permissions survive app updates. For a disposable ad-hoc build,
set both `SIGN_IDENTITY=-` and `ALLOW_ADHOC_SIGNING=1`; installing such a build
can make macOS request Screen Recording and Accessibility permissions again.

The script builds both `arm64` and `x86_64`, verifies the app signature and
release archive, and increments `BuildNumber` only after packaging succeeds.
Run `swift test` first; do not replace the installed application when tests or
either architecture fail to build.

To replace a local installation, quit the running app, preserve the old bundle
until the new one has been verified, copy the newly built `ExtendCast.app` to
`/Applications`, and launch it again. Confirm the installed build and signature:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  /Applications/ExtendCast.app/Contents/Info.plist
lipo -archs /Applications/ExtendCast.app/Contents/MacOS/BetterCastSender
codesign --verify --deep --strict /Applications/ExtendCast.app
```

A normal release should report both `arm64` and `x86_64` and retain the same
bundle identifier and signing Team ID as the previous installation. This keeps
Screen Recording and Accessibility authorization stable across replacements.
