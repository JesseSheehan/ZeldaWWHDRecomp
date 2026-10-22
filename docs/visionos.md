# Apple Vision Pro (visionOS)

The port runs on Apple Vision Pro as a visionOS app: the game in a window you can place and resize, the
Wii U GamePad's screen in a second window, a game controller, and the port's settings menu. Like every
build of this project, you make it yourself from **your own copy of the game**; nothing here contains game
code, game data or keys, and nothing you build from it may be shared.

## What you need

- A Mac with Apple Silicon, **Xcode 27** or later with the **visionOS SDK** (Xcode > Settings > Components),
  and CMake, Ninja and Python 3 (`brew install cmake ninja python`).
- An **Apple Vision Pro** with Developer Mode on (Settings > Privacy & Security > Developer Mode), paired with
  Xcode (Window > Devices and Simulators).
- An **Apple developer account**. A paid membership is recommended:
  - the app asks for the *Extended Virtual Address Space* capability (more address space for the game's
    memory); Xcode registers it for your App ID when it builds the app with automatic signing;
  - apps signed with a free account expire after 7 days and have to be built and installed again.
  The game's memory also fits without the capability (tested with a diagnostic, not yet in a whole play
  session): with a free account, try deleting the `com.apple.developer.kernel.extended-virtual-addressing`
  key from `visionos/WindWakerVision/WindWakerVision/WindWakerVision.entitlements` (keep that change local).
- **Your game**: the USA or European Wii U version, as an extracted folder (`code/`, `content/`, `meta/`, for
  example from the desktop port's installer, `data/game`), a disc image (`.wux` / `.wud`) with its disc key
  and the Wii U common key from your console, or a Cemu archive (`.wua`).
- A game controller paired with the Vision Pro (Switch Pro Controller, DualSense, Xbox and other MFi
  controllers). There are no touch controls.

## Building

1. **Clone the repository** and switch to the `visionos` branch.

2. **Build the game code and the runtime** with your game:

   ```sh
   tools/visionos/build.sh --game /path/to/game                # an extracted folder (code, content, meta)
   tools/visionos/build.sh --image /path/to/game.wux \
       --disc-key /path/to/game.key --common-key /path/to/common.key
   tools/visionos/build.sh --archive /path/to/game.wua
   ```

   It checks the tools, extracts the game (`--image` / `--archive`, into `build-visionos/game`), checks that
   `cking.rpx` is a version the port supports, recompiles it, and builds the runtime for visionOS (about 10
   minutes the first time). Keys are read from the files you name (or `--keys-stdin`) and never printed or
   stored. Everything goes into `build-visionos/`, which git ignores: it is derived from your game, so never
   commit or share it.

3. **Signing**: copy `visionos/Local.xcconfig.example` to `visionos/Local.xcconfig` and put your team ID in it
   (Xcode > Settings > Accounts). That file stays on your Mac (git ignores it).

4. **Build and install the app**: open `visionos/WindWakerVision/WindWakerVision.xcodeproj`, pick the
   *WindWakerVision* scheme and your Apple Vision Pro, and press Run (the first build registers the App ID and
   its capability with your team). From the command line:

   ```sh
   xcodebuild -project visionos/WindWakerVision/WindWakerVision.xcodeproj -scheme WindWakerVision \
       -destination 'id=<your device id>' -allowProvisioningUpdates build
   ```

   The bundle id is `dev.windwakervision.WindWakerVision`; if Xcode says it is taken, change
   `PRODUCT_BUNDLE_IDENTIFIER` to one of your own.

## Importing the game

The app needs the extracted game folder (about 1.7 GB) in its own storage. The first time it starts it
says *No game found*:

1. Put the game folder (the one with `code`, `content` and `meta`, e.g. `build-visionos/game`) somewhere the
   Files app on the Vision Pro can reach: iCloud Drive is the easiest (copy it into iCloud Drive on your Mac
   and wait for it to upload).
2. In the app, choose **Import Game Folder…** and pick that folder. The app checks that it is the version the
   app was built for and copies it (a minute or two).

Advanced, from the Mac (no iCloud):

```sh
xcrun devicectl device copy to --device <your device id> --domain-type appDataContainer \
    --domain-identifier dev.windwakervision.WindWakerVision --source build-visionos/game --destination Documents/game
```

The app only accepts the version its game code was recompiled from: a European build needs the European
game folder, and the other way round.

## Playing

- **Start the app from the Home View** for normal speed. Started from Xcode it runs under the debugger,
  which slows the game down (see Troubleshooting).
- **Controller**: the buttons work as on the Wii U GamePad (on a Switch Pro Controller, the button labelled A
  is A). **−** opens and closes the settings menu: Off-TV Play, its job on the Wii U, has no use here, and the
  system keeps the Home button. In the menu: D-pad to move, A to choose, B to go back, L / R for the tabs.
- **GamePad screen**: the gamepad button below the game window opens and closes the GamePad window; **+**
  (Start) also opens it. While it is closed, the GamePad screen is shown in a corner of the game window
  (picture-in-picture). Look at the GamePad window and pinch to touch it (the map, the items screen).
  Settings > Display chooses another GamePad screen mode (picture-in-picture, automatic, off, GamePad only).
- **Gear button** below either window: the settings menu, without the controller.
- Your saves are in the app's storage (`Documents/save`); the app's log is `Documents/captures/wwhd.log`.

### Recommended settings

Measured on an Apple Vision Pro (M2):

| Settings > Graphics | Result |
|---|---|
| Internal resolution 1x (1080p), 60 fps (frame interpolation) | steady 60 fps (**recommended**) |
| 1.5x (1620p), 60 fps | mostly 60, dips to about 47–55 in busy scenes |
| 2x (2160p), 60 fps | 41–51 fps, and the game slows down |
| 3x | about 28 fps |

The display runs at 90 Hz, so 60 fps is close to, but not perfectly, even.

## Troubleshooting

- **Xcode stops with `EXC_BAD_ACCESS` in `st32` or another memory access.** Usually expected: the runtime
  write-protects texture memory and takes the first write to each page as "this texture changed"
  (`runtime/src/write_watch.h`). The *WindWakerVision* scheme's LLDB init file (`visionos/WindWakerVision/lldbinit`)
  lets those through, and on visionOS write tracking is off while a debugger is attached. Choose the
  *WindWakerVision* scheme, not one Xcode made itself.
- **Very slow from Xcode.** The debugger, and the *WindWakerVision (Debug Metal)* scheme's Metal validation and
  frame capture, cost a lot. Start the app from the Home View to play.
- **A Metal validation assert** (only with the Debug Metal scheme): please report it with the message.
- **"This app was built for the … version"**: the imported game is another version than the one you built.
  Rebuild with that game (`tools/visionos/build.sh`) or import the matching one.
- **Signing errors**: check `visionos/Local.xcconfig` (team ID), and that Xcode is signed in to that team.

## How the visionOS port works

The runtime is the same as on the Mac: Metal renderer, native GX2, recompiled game code. What differs:
the runtime is a static library that the SwiftUI app links (`CMAKE_SYSTEM_NAME=visionOS` in CMake), its window
and input host is `runtime/src/platform/visionos/host.mm` instead of the AppKit one, the game's 4 GiB address
space sits at 0x7000000000 (visionOS reserves the lower addresses; `tools/visionos/memprobe` measured it), and
it is reserved before `main()` so nothing else lands there first.

## Legal

Use only a game you own, dumped from your own console with your own keys. Do not share the extracted game,
the keys, `build-visionos/`, or an app built from them: they contain or are derived from Nintendo's game.
