# ExtendCast for iOS and iPadOS

The iOS application is a receiver built with UIKit, Network.framework,
VideoToolbox, and AVFoundation.

Open `Package.swift` in Xcode to work on the target. The packaging script builds
an unsigned device IPA:

```bash
cd iOS
./package_ipa.sh
```

Installation still requires an Apple Development or Distribution signature and
a matching provisioning profile.
