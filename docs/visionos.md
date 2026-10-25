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
   `cking.rpx` is a version the port supports, recompiles it, builds the runtime for visionOS (about 10
   minutes the first time), and prepares the **shader head start** (below). Keys are read from the files you name (or `--keys-stdin`) and never printed or
   stored. Everything goes into `build-visionos/`, which git ignores: it is derived from your game, so never
   commit or share it.

   **Shaders**: the desktop release's setup prepares the game's shaders ahead so new areas don't stutter;
   `build.sh` does the same for the app. It needs the code-free shader template from a desktop release
   (`tools/shadercache/template.bin` in the release folder): put it at `tools/shadercache/template.bin` in
   this repository (git ignores it), or pass `--shader-template /path/to/template.bin`. It writes
   `shadercache/headstart.bin` (about 90 MB) into the game folder, so it is imported with the game.
   Without a template the step is skipped (`--no-shaders` skips it too) and shaders compile while you play.

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
- **Motion aiming** (on unless turned off: Settings > Vision Pro > Motion aiming, or Settings > Controls >
  Gyro... with sensitivity, invert and recalibrate): the controller's motion sensors (DualSense, DualShock
  4, Switch Pro Controller) are the GamePad's, so you aim the bow, hookshot, boomerang, telescope and
  first-person view by moving the controller, as on the Wii U. The Vision Pro tab shows whether motion
  arrives. The game's own Options > Gyro switch has to be on, and the right stick still.
- **Gear button** below either window: the settings menu, without the controller.
- **Full Screen**: the full-screen button below the game window, or Settings > Vision Pro. The game moves
  to a big, slightly curved screen: on The Great Sea under a bright sky, with the picture reflected
  in the water (turn the Digital Crown to bring your room back in), or in your room, dimmed or as it is.
  The sea and sky wear the game's own wave patterns, clouds and sun, read from your imported game folder
  when Full Screen opens (nothing from the game is part of the app; without them, plain shapes). The sky
  follows the game's time of day (the headset's clock before a game is loaded): dawn, day, dusk and night
  colour the sky, sea and clouds, and the sun rises and sets. The game's reflection lies see-through under
  the wave lines and sways gently.
  The GamePad window opens with it and carries the full-screen controls below the GamePad picture: the
  screen size (Small 3 m wide 4 m away, Medium 5 m at 7 m, Huge 12 m at 12 m), the surroundings, Settings,
  leaving full screen, and hiding the GamePad picture (the window then holds only the controls, and the
  GamePad picture shows as picture-in-picture on the big screen). Move it wherever you like. If you close
  it, + opens it again and the controls float under the big screen meanwhile; Settings > Vision Pro does
  the same with the controller, and pressing the Digital Crown leaves full screen too. The choices are
  remembered. (Apple's own environments, such as Mount Hood, take only video players: the
  game cannot dock into them.)
- **3D** (Settings > Vision Pro > 3D, in the game window and in Full Screen, experimental): each eye gets its own picture, made
  from the game's depth, so the world has depth while the HUD and menus stay at the screen. Depth sets
  how strong it is; Swap eyes if it looks inside out. Off, it costs nothing.
- **Closed the game window?** The game keeps running in the GamePad window. Press **−** or **+** (that press
  only reopens the window: it doesn't open Settings or reach the game), or the TV button below the GamePad
  window.
- **First start**: with a shader head start in the game folder, the app compiles it once before the game
  starts (*Preparing shaders*, with a progress bar). visionOS keeps the compiled shaders, so later starts
  are quick; if the system clears the app's caches, the app prepares them again on its next start.
- **Typing**: when the game asks for text (the name of a new save file), its on-screen keyboard shows as
  usual and works with the controller alone; the visionOS keyboard comes up with it, and what you type
  there (or on a paired keyboard) goes into the name. Text fields in the settings menu open a system text
  box.
- **Pause and resume**: when the app leaves the front (headset off, the Home View, another app in front),
  the game pauses, sound and game time included, and continues where it was when you come back. Before
  pausing, during play, it writes a *Last session* state (the save states' Last session slot; a few KB, separate from
  your saved games, which it never touches). If visionOS ends the app meanwhile, the next start asks
  **Resume where you left off?**: choose *Resume*, then your Quest Log on the title screen, and the game
  continues from that moment; *Start as Usual* ignores it.
- Your saves are in the app's storage (`Documents/save`); the app's log is `Documents/captures/wwhd.log`.

### Recommended settings

Measured on an Apple Vision Pro (M2):

| Settings | GPU per frame | Result |
|---|---|---|
| Internal resolution 1.25x (900p), 60 fps, Vision Pro > Sharper picture (MetalFX) on | about 13 ms | steady 60 fps, sharp (**recommended**) |
| 1x (720p), 60 fps, MetalFX on | about 11 ms | steady 60 fps |
| 1.5x (1080p), 60 fps | about 16.4 ms | mostly 60, dips in busy scenes (Dynamic resolution "Down to 75%" holds it) |
| 1.5x, 45 fps | | steady, evenly paced on the 90 Hz display |
| 1x, 90 fps, MetalFX on | about 11 ms | 75–85 fps (90 needs under 11 ms a frame); at 1.25x and up it draws 60 |
| 2x (1440p), 60 fps | about 27 ms | 41–51 fps, and the game slows down |
| 3x | | about 28 fps |

The game logic keeps 30 steps a second in every frame rate mode (measured).

For a sharper picture at 60 fps: **Settings > Vision Pro > Sharper picture (MetalFX upscaling)** enlarges
the picture to the window's (or Full Screen's) real pixels with Apple's MetalFX instead of plain filtering,
for very little GPU time; it helps most at 1x to 1.5x. 1.25x (1600x900) sits between 1x and 1.5x, and
Graphics > Dynamic resolution (down to 75 %) keeps 1.5x at 60 fps by lowering it only in busy scenes.
On the 90 Hz display, 60 fps shows its frames for 2 and 1 refreshes in turn. Graphics > Frame rate offers
45 fps (3 frames for every 2 game steps, each shown for 2 refreshes: even, and cheaper than 60) and 90 fps
(2 in-between frames per step, each shown for 1 refresh: even, and the smoothest, but about 50 % more GPU
than 60). The game logic keeps its 30 steps a second in every mode.
With the performance overlay on, the log (`Documents/captures/wwhd.log`) gets its GPU and CPU averages
every 300 frames (`[perf]` lines).

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
- **Stutters in new areas**: the game folder you imported has no `shadercache/headstart.bin` (build it with
  `build.sh` and a shader template, then import the folder again), or *Preparing shaders* was interrupted
  (it runs again at the next start).
- **Simulator**: the app also runs in the visionOS simulator, for testing. Configure a second build directory
  with `-DCMAKE_OSX_SYSROOT=xrsimulator` (as `build.sh` does for the device), and point simulator builds at it
  in `visionos/Local.xcconfig`: `WWHD_RUNTIME_BUILD[sdk=xrsimulator*] = /path/to/that/build`.

## How the visionOS port works

The runtime is the same as on the Mac: Metal renderer, native GX2, recompiled game code. What differs:
the runtime is a static library that the SwiftUI app links (`CMAKE_SYSTEM_NAME=visionOS` in CMake), its window
and input host is `runtime/src/platform/visionos/host.mm` instead of the AppKit one, the game's 4 GiB address
space sits at 0x7000000000 (visionOS reserves the lower addresses; `tools/visionos/memprobe` measured it), and
it is reserved before `main()` so nothing else lands there first.

- **Shaders**: the head start is the desktop's (`tools/shaderprep.py`, `runtime/src/gfx/shader_headstart.mm`),
  read from `<game>/shadercache/headstart.bin`. visionOS has no setup step, so the first start runs the
  desktop's `--warm-shaders` compile in-process before the game thread starts (`main.cpp`), and a marker in
  `Library/Caches/wwhd` records which head start that was. Metal binary archives can't be made on the Mac
  ahead of time: the runtime generates its Metal shaders from the game's GPU code while it runs, so there is
  no shader library to compile offline, and visionOS's own shader cache plays that part after the first start.
- **3D** (`runtime/src/gfx/depth3d.h`): the Metal renderer copies the scene's depth and colour at the
  frame's first HUD (layout) draw onto a target of the scene's size (`metal_draw.mm depth3d_track`); the host
  makes the two eye pictures from the TV picture with that depth (`depth3d_fs`: each pixel shifted by a
  disparity linear in the depth buffer around the depth near the centre; where the picture differs from the
  scene without the HUD, unshifted) and draws them side by side into the Full Screen texture, which the
  screen's ShaderGraph material (`Resources/StereoScreen.usda`, RealityKit's Camera Index Switch) shows each
  eye its half of. The game window shows the game on such a screen too (`StereoWindowScreen`, over the window's
  layer view, which stays for the controller and keyboard). The screen texture is always two pictures wide:
  with 3D off the same picture is drawn into both halves, so switching 3D only changes what is drawn.
  `WWHD_TEST_THEATER=stereo` checks the material with a test picture.
- **Text**: `runtime/src/platform/visionos/text_input.mm`, the counterpart of `gfx/text_input_appkit.mm`.
- **Full Screen**: `visionos/WindWakerVision/WindWakerVision/Theater.swift` (an immersive space, its
  screen and surroundings made of simple unlit shapes in code) and `runtime/src/platform/visionos/theater.mm`:
  the screen's texture is a RealityKit `DrawableQueue`, and the host composes the TV picture into it instead
  of the TV window's layer, in the same render pass. The reflection is a second mesh that samples the same
  texture (the mirrored screen laid onto the water as seen from about 1.2 m up), darker and fading out: no
  copy. The game's scenery (`GameScenery.swift`, `runtime/src/platform/visionos/game_textures.cpp`) comes from
  `permanent_3d.pack` (Always: the wave patterns `umipt` and `b_wyurayura_tex1`, the sun `txa_taiyo`) and
  `sea_T_Stage.szs` (the clouds `cloudtx_01`-`03` and the horizon strips `ws_mae08`...), untiled with
  LatteAddrLib and BC-decoded on the device; the waves scroll and the clouds drift by texture offsets.
  The reflection is drawn just under the wave layers, about 55 % opaque at the waterline;
  `SkyClock.swift` reads the time of day (`wwhd_visionos_time_of_day`: dSv_info_c +0x44) about once a
  second. `WWHD_TEST_HOUR=18` shows a fixed hour.
  `WWHD_TEST_THEATER=1` enters full screen at start, `=pattern` with colour bars instead of the game.
- **Pause**: `runtime/src/app_pause.cpp` stops the game's main thread at a frame boundary, freezes the other
  guest threads as a save state does, stops the audio device, and on resume sets the guest clock back to
  where it stopped. The host (`host.mm`) asks for it when the app resigns active, after
  `ss::save_last_session`.

## Legal

Use only a game you own, dumped from your own console with your own keys. Do not share the extracted game,
the keys, `build-visionos/`, or an app built from them: they contain or are derived from Nintendo's game.
