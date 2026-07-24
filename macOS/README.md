# ExtendCast for macOS

The macOS application contains sender and receiver modes in one Swift package.

```bash
cd macOS
swift test
./build.sh
```

`build.sh` produces a signed Universal 2 application and ZIP in this directory.
Set `SIGN_IDENTITY=-` to use ad-hoc signing.
