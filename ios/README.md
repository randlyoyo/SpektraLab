# SpektraLab Mobile (unofficial iOS port)

The SpektraLab engine (C++ + Metal) on iPhone, with a small SwiftUI front end:
pick a photo, choose a film and a paper, set exposure, grain and halation, save
the print to Photos. Personal and TestFlight use; not an official SpektraLab
build. Please give any public build its own name and icon (see the top-level
README, "Trademark").

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
- One photo at a time. No crop, Film Edge, Date Back or batch.
- Output is Display P3 HEIC.

## Licences

The app and engine are GPL-3.0-or-later; the film and paper profiles and print
LUTs are CC BY-SA 4.0 (spektrafilm by Andrea Volpato). The licence texts ship
in the app bundle under `Licenses/`.
