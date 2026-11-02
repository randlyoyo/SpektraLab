# SpektraLab Mobile: design prototype

A Flutter mock-up of the iPhone app's screens, used to settle layout and
interaction on a PC with no Mac. The shipping app is native SwiftUI, in
`../ios`. Make design changes here first, then port them there.

```powershell
cd mobile
flutter run -d chrome
```

The app runs inside an iPhone frame (`device_preview`). Press `r` in the
terminal to hot reload. There is no film engine here: picked JPEGs are shown
unprocessed (`lib/engine.dart`).
