# Beamstage 7

Projection mapping for macOS that drives a LaserCube directly. You don't need LaserOS.

Beamstage 7 is a single native app. It maps video onto objects with a projector and draws laser outlines, presets or traced video that line up with the projection.

## Start

1. Unzip **Beamstage-7-mac.zip** and move **Beamstage 7.app** to Applications. It runs on macOS 12 or newer, on Apple silicon and Intel Macs.
2. Open it. macOS blocks it the first time, because the app isn't signed by a registered Apple developer. Go to **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.
3. When macOS asks whether Beamstage 7 can find devices on your local network, click **Allow**. It needs that to reach the cube.

Your work is saved automatically. Use **File > Save** to keep a named `.beamstage` project. Beamstage 7 can open projects from Beamstage 4.

## Map a video

1. Connect the projector as an **extended** display, not mirrored, at its native resolution. Leave **Displays have separate Spaces** on.
2. Click **Output window** and choose the projector. Double-click the output, or press **F**, to switch between fullscreen and a window.
3. Drop MP4, MOV, GIF, PNG or JPEG files onto the editor. The first clip replaces the test pattern.
4. Drag the coloured corners until the picture sits on your object. Use the arrow keys for fine moves (Shift for 10 px), and Tab for the next point.

| Tool | Where | What it does |
|---|---|---|
| Add surface | Map tab | A surface for each face of your object |
| Bend grid | Map tab | More points, for curved surfaces |
| Crop video | Map tab | Shows part of a clip on one face |
| Soft edge | Map tab | Feathered edges for blending |
| Masks | Map tab | Blacks out areas for the projector *and* the laser. Double-click to add a point, Option-click to remove one |
| Send to laser | Map tab | Whether a surface is drawn by the laser |

MOV files play through macOS itself, so ProRes and HEVC work.

## Connect the LaserCube

The cube needs to be on Wi-Fi or Ethernet. USB isn't supported.

1. Quit LaserOS, or at least disconnect the cube in it. Only one app should drive the cube at a time.
2. Join the Mac to the same network as the cube, or to the cube's own Wi-Fi.
3. Open the **Laser** tab. Beamstage looks for cubes when it starts. Click **Find LaserCubes** to look again, or type the cube's IP address and click **Add**.
4. Click **Connect**. The panel shows the cube's model, network, temperature and interlock.
5. Keep **Power limit** low, then click **Turn on laser** and confirm the safety checks.

Connecting never turns the beam on. **Esc** turns it off.

### What the laser draws

| Mode | Draws |
|---|---|
| Surface outlines | The edge of each surface marked **Send to laser**, in the colour you choose |
| Preset | An animated shape: across the laser's whole area, or fitted onto each laser surface so it sticks to your object |
| Scan bold shapes | Finds the boldest, most contrasting parts of the video and turns them into a few clean lines |
| Trace the projection | Moving outlines traced from the projected picture, in the video's colours |
| Trace selected surface | Only the selected surface's video, traced |
| Calibration crosses | A cross on every calibration point |

### Presets

Circle, Square, Triangle, Star, Flower, Heart, Spiral, Tunnel, Wave, Lissajous, Scanner and Grid.

- **Colour:** white, red, green, blue, cyan, magenta, yellow or rainbow.
- **Size** and **Speed.**
- **Place:** across the whole laser area, or on the laser surfaces. Placed on surfaces, a preset follows the corners and bend grid, so a star drawn on a box face stays on that face.

### Scan bold shapes

Busy video, like a spiral of hundreds of thin lines, is too much for a laser to trace line by line. **Scan bold shapes** looks for the parts that stand out: bright strokes that are thick or packed closely together. It turns those into a simple guide for the laser.

1. Choose **Scan bold shapes** under **What the laser draws**.
2. Choose what to scan: the whole **Projection**, or the **Selected surface** only.
3. Click **Scan frame** to freeze the current frame. The laser traces it until you click **Follow video**, which scans every frame as the video plays.
4. Set **Sensitivity**. Low keeps only the boldest core of the picture, and high takes in more of it.
5. Pick a version from the thumbnails. Next to the snapshot of the scanned frame, you'll see:

| Version | What the laser draws |
|---|---|
| Outline | The smooth edge of each bold shape, holes included |
| Centre line | One line through the middle of each bold stroke. The simplest guide, with the fewest points |
| Detail | The bright strokes inside the bold shapes |

Sensitivity and the version also apply to a frozen frame, so you can adjust them after scanning.

#### Colours

Each version has its own colour profile, shown by the swatch under its thumbnail. Select a version, then choose its colour below the thumbnails:

| Profile | Colours the lines |
|---|---|
| Video colours | In the colour each line has in the video |
| Solid | In one colour. Pick it with the colour well, or use a chip such as White, Red or Gold |
| Gradient | From one colour to another along each line. Fire, Ice, Sunset and Toxic are ready-made |
| Rainbow | Through the rainbow along each line |
| Per shape | Each bold shape in a different colour |

Gradient, Rainbow and Per shape can cycle: set **Speed** above Still. Changing a colour never needs a re-scan.

#### Overlapping

You can draw more than one version at once. Each thumbnail has a tick in its corner: tick Outline and Centre line, for example, and the laser draws both, each in its own colours. Clicking a thumbnail selects it for colour editing, and switches it on if it was off.

You can also overlap saved profiles. Under **Overlap profiles**, switch on any other saved profile and the laser draws it as well, with that profile's own sensitivity, versions and colours. A profile with a saved frame draws that frame; the others follow the live video. So you can mix, say, a frozen bold outline with a live centre line, or a projection scan with a scan of one surface. Each switched-on profile shows a small preview of what it's adding.

Everything overlapping shares the laser's points. If the picture gets busy, the laser drops the smallest shapes first. Lower the sensitivity or draw fewer versions to keep it clean.

#### Scan profiles

A profile saves the source, sensitivity, the versions it draws and all three colour profiles. If you've frozen a frame with **Scan frame**, the profile saves that frame too (shown as "· frame"). Loading the profile then brings the exact shape back.

- **Pick** a profile from the **Profile** menu to load it.
- **Save** stores the current settings in the profile you're using. **Unsaved changes** tells you when they differ.
- **New…** saves the current settings as a new profile, with a name.
- The **⋯** menu renames, reverts to saved, or deletes the profile.

Beamstage starts with three: **Bold outline**, **Simple guide** (a white centre line) and **Fire detail**. Profiles belong to the app rather than to a project, so every show can use them. They're stored in `~/Library/Application Support/Beamstage 7/Scan profiles`.

## Calibrate the laser to the projector

The laser and the projector sit in different places, so their pictures don't line up on their own. Do this once for each rig:

1. Connect the cube and turn the laser on at low power.
2. In the **Laser** tab, click **Calibrate laser** (⌘K). The output opens on the projector, and the steps appear on the projection.
3. For each point, find the laser's circled cross on the wall and **click on it**. The laser jumps onto the projector's matching cross. Click again, drag it, or use the arrow keys to fine-tune. Then click **Next point**, or press Return.
4. After the last point, both draw a test grid. Where they line up you see one line, and where you see two, click **Redo points**. Otherwise click **Done**.

You can aim from either screen. The steps and the aiming ring appear on the projector and in the editor. Move the mouse over either one, and the ring on the wall follows it. So you can watch the wall and steer with the mouse on your own screen.

It doesn't matter how the cube is mounted. Calibration learns which way the laser moves from your clicks. If the cube is on its side, upside down or mirrored, calibration sets the orientation (under **Scanner**) for you and tells you it did, so presets and the lowest line stay upright. A slight tilt is corrected by the calibration itself.

If a point is out of the laser's reach, the panel tells you and holds the cross at the edge. Move the cube or the projector so the laser covers that corner, or click **Next point** to leave it.

**More options** lets you change the number of points:

- **4** points fix position, size and keystone.
- **9, 16 or 25** points also fix lens bending, which shows as curved lines near the edges.

The same panel lets you edit points by hand. **Check** shows the test grid at any time without changing anything.

## Scanner settings

| Setting | What it does |
|---|---|
| Orientation | Turns the whole laser picture: 90° buttons, a fine **Rotate** slider, and flips. For a cube that's on its side, tilted or mirrored. Calibration sets this for you when it's needed |
| Lowest line | Nothing is lit below this line. Set it so the beam can never reach eye level. It's drawn in red in the Laser view |
| Scan rate | Points per second sent to the cube (up to 30k) |
| Frame rate | Lower rates give each frame more points, so busy pictures flicker less |

Beamstage also publishes the laser picture over Syphon as **Beamstage Laser**, and the clean projector picture as **Beamstage Output**, for monitoring or other software.

## Phone remote

Run calibration and the show from your phone while you stand at the wall.

1. In the **Output** tab, turn on **Phone remote**.
2. Scan the QR code. Your phone must be on the same Wi-Fi as the Mac.

The phone page has:

- **STOP LASER**, always at the top.
- A trackpad and arrow pad for calibration.
- Preset and colour buttons.
- The laser mode and tests.
- Show controls.

The phone can lower the power limit but never raise it. It can't turn the laser on: that happens only at the Mac, after the safety confirmation. The link carries a private key, so devices without it can't connect.

## Laser safety

Lasers like these can cause instant eye injury and start fires. This software is not a safety system.

- Never aim the beam at people, animals, aircraft, cameras or shiny surfaces.
- Set **Lowest line** so nothing scans below a safe height.
- Keep the cube's key or interlock within reach. The hardware is your real stop button.
- Check the rules where you are. Public laser shows often need a permit or a licensed operator.

The software adds these protections:

| Protection | What it does |
|---|---|
| Off by default | Connecting never turns on the beam. Turning it on asks you to confirm the safety checks |
| Stop | **Esc**, **Stop laser** or the phone's **STOP LASER** turns the output off |
| Power limit | Applied to every point. It starts at 20% each time you open Beamstage |
| Lowest line | Blanks every point below it |
| Frame watchdog | The beam turns off within 0.75 s if Beamstage stops producing frames |
| Spot-beam guard | Blanks any frame that would hold the beam in one small area |
| Device checks | Stops on interlock, overheating or lost contact |
| Blanked moves | The beam is off while the mirrors jump between shapes |
| Quitting | Turns the output off |

If Beamstage is force-quit or the network drops, the cube only draws what's left in its small buffer, then stops. Treat the hardware interlock as the stop that always works.

## Keys

| Key | Action |
|---|---|
| Esc | Stop the laser (and cancel calibration) |
| Space | Play or pause |
| Arrows | Nudge the selected point or surface (Shift for 10 px) |
| Tab | Next point |
| Delete | Delete the selected mask point, surface or mask |
| G / B / F | Guides on the projector / Projector blackout / Output fullscreen |
| T | Cycle laser tests |
| ⌘K | Calibrate the laser |
| ⌘L | Projector or Laser view |
| ⌘Z / ⇧⌘Z | Undo / Redo |

## If something doesn't work

- **"No LaserCube found":** check that the Mac and cube share a network, and that a VPN or firewall isn't blocking local traffic. Try typing the cube's IP address.
- **"macOS may be blocking network access":** open **System Settings > Privacy & Security > Local Network** and turn on Beamstage 7. Each new build of an unsigned app can count as a new app, so you may need to do this again after rebuilding.
- **Turn on laser is greyed out:** the cube's interlock is open (turn the key), or the cube is overheating.
- **The laser is turned, tilted, mirrored or upside down:** calibrate, and Beamstage sets the orientation. To set it yourself, use **Orientation** under **Scanner**.

## Build from source

You need only the Xcode Command Line Tools (`xcode-select --install`).

```
./build.sh
```

This builds `build/Beamstage 7.app` (universal) and `build/Beamstage-7-mac.zip`. Checks:

| Command | What it does |
|---|---|
| `Beamstage --check` | Syphon self-test |
| `Beamstage --render-test <dir> [media]` | Renders the projector and runs the geometry and calibration tests |
| `Beamstage --laser-test <dir> [media]` | Plans every preset and mode, checks them against the spot-beam guard and the lowest line, traces the media, and writes scan previews |
| `Beamstage --scan-test <image> <dir>` | Scans an image at three sensitivities in every version, and checks the colour profiles. It also round-trips a scan profile with its snapshot (in a scratch folder) and renders a preview of the Scan panel |
| `Beamstage --find-cubes [ip]` | Lists LaserCubes. Read-only, so it never turns anything on |
| `Beamstage --cube-test 127.0.0.1` | Drives a fake cube through arming, streaming, the watchdog and the interlock. It refuses to run against a real cube |

The fake cube is `tools/fake-lasercube.mjs` (`node tools/fake-lasercube.mjs`). It reports the interlock bit the way real cubes do.

## How it works

- **Rendering:** Swift, AppKit and SwiftUI, with Metal. Shaders compile at launch.
- **Surfaces:** each is a grid warp. That's one perspective transform through its corners, plus a smooth correction through the inner points, so lines never tear at grid borders.
- **Laser driver** (`Sources/LaserCube.swift`): speaks the LaserCube network protocol over UDP on its own real-time thread. It uses the same flow control and safety logic as Beamstage 3, whose protocol details come from the MIT-licensed [laser-dac](https://crates.io/crates/laser-dac) crate.
- **Planner** (`Sources/LaserPlanner.swift`):
  - turns shapes into a scan, with blanked moves, corner dwell and a point budget;
  - when a frame is too long, it spaces the points out first, then drops the smallest shapes.
- **Video tracing:** renders a small copy of the picture, then follows its edges with marching squares.
- **Scan bold shapes** (`Sources/LaserScan.swift`):
  - blurs the frame's brightness, so thick or packed strokes score higher than thin, isolated lines;
  - keeps the top share of the frame set by Sensitivity;
  - outlines that area, thins it to a centre line, or traces the bright strokes inside it;
  - runs on a background queue, so playback isn't slowed.
- **One frame everywhere:** the same planned frame goes to the cube, the Laser view and Syphon, so what you see is what the cube draws.
- **Phone remote:** a small HTTP server on port 4797, built into the app.
- **Syphon:** included under its BSD licence (`vendor/Syphon-License.txt`).
