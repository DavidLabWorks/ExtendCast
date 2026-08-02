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
