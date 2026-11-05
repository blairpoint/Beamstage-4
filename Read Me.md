# Beamstage 4

Projection mapping for macOS, with a Syphon laser feed for LaserOS and other Syphon apps.

Beamstage 4 is a single native app. Unlike Beamstage 3, it doesn't need Node.js, a browser or a Terminal bridge. You double-click it and it runs.

## Start

1. Unzip **Beamstage-4-mac.zip** and move **Beamstage 4.app** to Applications. It runs on macOS 12 or newer, on both Apple silicon and Intel Macs.
2. Open it. The app isn't signed by a registered Apple developer, so macOS blocks it the first time. Go to **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.

Your work is saved automatically and comes back the next time you open the app. Use **File > Save** to keep a named `.beamstage` project.

## Map a video

1. Connect the projector as an **extended** display (not mirrored), at its native resolution. Leave **Displays have separate Spaces** on.
2. Click **Output window** and choose the projector. The output fills that display. Double-click the output, or press **F**, to switch between fullscreen and a window.
3. Drop MP4, MOV, GIF, PNG or JPEG files onto the editor. Your first clip replaces the test pattern on the first surface.
4. Drag the coloured corners until the picture sits on your object. Click a corner and use the arrow keys for fine moves. Hold Shift for 10 px steps, and press Tab to move to the next point.

The projector shows the same guides while you work. Press **G** to hide them.

| Tool | Where | What it does |
|---|---|---|
| Add surface | Map tab | Adds a surface for each face of your object |
| Bend grid | Map tab | Adds columns and rows of points for curved surfaces |
| Crop video | Map tab | Shows part of a clip on one face |
| Soft edge | Map tab | Feathers the edges so overlapping projectors blend |
| Masks | Map tab | Blacks out windows, doors and anything that shouldn't be lit. Double-click to add a point, Option-click to remove one |
| Test pattern / Solid white | Media pickers | Built-in sources for lining things up |

MOV files play through macOS itself, so ProRes and HEVC work without conversion.

## Laser mapping over Syphon

Beamstage publishes two Syphon servers:

| Server | Content |
|---|---|
| **Beamstage Laser** | A feed made for laser tracing, corrected to line up with the projector |
| **Beamstage Output** | The clean projector picture, for other Syphon apps |

Guides never go out over Syphon.

### Connect LaserOS

1. Open Beamstage, then LaserOS, and connect your cube in LaserOS.
2. Open **Cast** in LaserOS and choose **Beamstage 4: Beamstage Laser** as the source. The exact wording may differ in your version of LaserOS.
3. In Beamstage, the **Laser** tab changes to **An app is connected**.

LaserOS controls laser power and safety. Start Cast at low power.

### Choose what goes to the laser

| Mode | Sends |
|---|---|
| Surface outlines | White edges of each surface marked **Send to laser**, on black. Gives the cleanest laser lines |
| Filled surfaces | Each laser surface filled white, so the tracer draws one outline per shape |
| Projection output | Exactly what the projector shows |
| Selected surface | Only the selected surface's video, in place |
| Calibration crosses | A cross on every calibration point |

Masks black out the laser feed as well as the projector. You can also set the feed's size and frame rate. Frames only go out while an app is connected.

### Calibrate the laser to the projector

The laser and the projector sit in different places, so their pictures don't match on their own. Do this once for each rig:

1. Start LaserOS Cast at low power.
2. In Beamstage's **Laser** tab, click **Calibrate laser** (⌘K). The output opens on the projector, and the steps appear on the projection itself.
3. Each point shows a circled cross from the projector and one from the laser, in the same colour. Find the laser's circled cross on the wall and click on it. The laser jumps onto the projector's cross.
4. If it isn't quite there, click it again, drag it, or use the arrow keys. Then click **Next point**, or press Return.
5. After the last point, the projector and laser both draw a test grid. Where they line up, you see one line. Where you see two, click **Redo points**. Otherwise click **Done**.

**Cancel** or **Esc** puts the calibration back the way it was. A large pointer ring makes the mouse easy to find on the wall. You can also click in the editor instead of on the output.

Under **More options**:

| Option | What it does |
|---|---|
| Points | **4** fixes position, size and keystone. **9, 16 or 25** also fix lens bending, which shows up as curved lines near the edges |
| Flip left/right, Flip up/down | For mirrored laser setups. Set these before you calibrate |
| Edit points by hand | Drag points in the Laser view |

**Check** shows the test grid at any time without changing anything. You can also test your real surfaces with **My surfaces**, and **Blink** helps you tell the projector's lines from the laser's.

## Phone remote

Run calibration and the show from your phone while you stand at the wall.

1. In the **Output** tab, turn on **Phone remote**.
2. Scan the QR code with your phone's camera. Your phone must be on the same Wi-Fi as the Mac.

| On the phone | What it does |
|---|---|
| **BLANK LASER** | Blanks the laser feed. Always at the top. Tap again to resume |
| Calibrate laser / Check | Starts calibration or the test grid |
| Trackpad | Drag to move the laser's circled cross. Fine, Normal and Fast set the speed |
| Arrow pad | One-step nudges. Hold to repeat. ×10 for bigger steps |
| Back / Next / Cancel / Done | Steps through calibration |
| Show | Play or pause, restart clips, projector blackout, guides |
| Laser feed | What to send, and the outline or grid tests |

The QR link carries a private key. Devices without it can't control Beamstage. If macOS asks whether Beamstage can accept incoming connections, choose **Allow**. Turn the remote off when you don't need it.

## Laser safety

Lasers like these can cause instant eye injury and start fires. This software is not a safety system.

- Never aim the beam at people, animals, aircraft, cameras or shiny surfaces.
- Keep the key or interlock within reach. The hardware is your real stop button.
- Check the rules where you are. Public laser shows often need a permit or a licensed operator.

**Esc** blanks the laser feed at any time and stays blanked until you click **Resume**. Esc also takes the output out of fullscreen if it covers the control window. Quitting Beamstage sends a black frame first. LaserOS might keep drawing its last frame, so use LaserOS's own stop or the hardware interlock as your real stop.

## Keys

| Key | Action |
|---|---|
| Esc | Blank the laser feed (and cancel calibration) |
| Space | Play or pause |
| Arrows | Nudge the selected point or surface (Shift for 10 px) |
| Tab | Select the next point |
| Delete | Delete the selected mask point, surface or mask |
| G | Show or hide guides on the projector |
| B | Black out the projector |
| F | Switch the output between fullscreen and a window |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘L | Switch between the Projector and Laser views |
| ⌘K | Start laser calibration |
| Return / Shift-Return | Next / previous calibration point |
| Click on the projection | During calibration: "the laser's cross is here" |
| T | Cycle laser tests (off, outlines, grid) |

## Build from source

You need only the Xcode Command Line Tools (`xcode-select --install`).

```
./build.sh
```

This builds `build/Beamstage 4.app` (universal) and `build/Beamstage-4-mac.zip`, then runs a Syphon self-check. To build Apple silicon only, use `ARCHS=arm64 ./build.sh`.

Checks:

```
"build/Beamstage 4.app/Contents/MacOS/Beamstage" --check
"build/Beamstage 4.app/Contents/MacOS/Beamstage" --render-test out "Test files/test-shapes.gif"
```

The first should print `ok Syphon server started and published a test frame`. The second renders the projector and every laser mode to PNG files in `out`, and runs the geometry checks.

## How it works

The app is written in Swift with AppKit and SwiftUI and renders with Metal. Shaders are compiled when the app starts, so no Metal toolchain is needed to build it.

- Each surface is a grid of control points, drawn as a finely divided mesh. A plain four-corner surface is exactly perspective-correct.
- The laser feed renders the same scene through the laser calibration. That's one perspective transform through the outer points, plus a smooth correction that passes exactly through every inner point. Bend grids work the same way, so lines never tear at grid borders. Laser lines are subdivided, so they follow the correction.
- The phone remote is a small HTTP server on port 4790, built into the app. The page is `resources/remote.html`. Every request must carry the pairing key.
- A calibration click works like this: the laser's cross is seen at point X, but it should be at target t. Beamstage moves that laser point by T(t) − T(X), where T is the current laser transform. A few clicks bring it within a pixel, even when the laser is mirrored.
- Video decodes through AVFoundation straight into Metal textures. GIF and image frames load through ImageIO.

| Path | Contents |
|---|---|
| `Sources/` | The app's Swift source |
| `vendor/Syphon.framework` | Syphon, included under its BSD licence (`vendor/Syphon-License.txt`). The prebuilt framework comes from the node-syphon project (MIT) |
| `resources/` | The app icon |
