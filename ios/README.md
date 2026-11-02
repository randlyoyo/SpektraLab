# SpektraLab Mobile (unofficial iOS port)

The SpektraLab engine (C++ + Metal) on iPhone, with a native SwiftUI front end.
Import several photos and pick a film and a paper for each. Set exposure,
grain and halation. Compare against the original by holding the photo, with
the 原图 toggle, or with a split slider. Edit several selected photos at once,
sync chosen settings from one photo to others, copy and paste settings, and
export a batch to Photos. For personal and TestFlight use; this is not an
official SpektraLab build. Please give any public build its own name and icon
(see the top-level README, "Trademark").

The layout is designed first in the Flutter prototype in `../mobile`
(`flutter run -d chrome`), which runs on a PC without a Mac.

## Build without a Mac

GitHub Actions does the Mac part (`.github/workflows/ios.yml`): push to the
`ios` branch of your fork, or run the workflow by hand, then download the
`SpektraLabMobile-unsigned-ipa` artifact.

Install it with [Sideloadly](https://sideloadly.io) on Windows: connect the
iPhone, drop in the .ipa, sign in with your Apple ID. A free Apple ID signs for
7 days. On the phone, turn on Settings → Privacy & Security → Developer Mode
and trust the profile under Settings → General → VPN & Device Management.

## Build on a Mac

```bash
engine/build.sh ios        # iPhone kernels + engine resources into ios/
cd ios && xcodegen         # brew install xcodegen
open SpektraLabMobile.xcodeproj
```

Re-run `engine/build.sh ios` whenever `engine/resources/` or the shaders change.

## Limits of this first version

- Input is scaled to 12 MP (`Engine.maxInputPixels`) to stay under the
  phone's memory limit.
- Settings and imported photos are not kept after the app quits.
- There is no crop, Film Edge or Date Back.
- Output is Display P3 HEIC.

## Licences

The app and engine are GPL-3.0-or-later; the film and paper profiles and print
LUTs are CC BY-SA 4.0 (spektrafilm by Andrea Volpato). The licence texts ship
in the app bundle under `Licenses/`.
