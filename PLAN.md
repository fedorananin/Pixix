# Pixix — application plan

An image viewer and editor for macOS. It views photos like Windows 11 Photos, converts in a couple of clicks, and edits with layers at the level of Paint.NET. Built by Fedor Ananin for his own machine, and published as open source at <https://github.com/fedorananin/Pixix> for anyone who wants it.

Status: phases 0–5 are implemented and phase 6 partly; section 9 has the details and section 12 lists what is missing. Sections 1–8 describe the design as built.

## 1. Goals and non-goals

Goals, most important first:

1. Opens instantly; closing the window removes it from the Dock.
2. Browsing every image in the folder: on-screen arrows, keyboard, swipe.
3. Conversion and resizing in one dialog with clear settings.
4. Quick edits: crop, aspect ratio, stretch, sliders, arrows, text, blurring and pixelating regions.
5. Layers: stack several images on top of each other, extend the canvas.
6. A full raster editor at the level of Paint.NET.

Non-goals: photo catalog or library, cloud, RAW development, plugins, App Store, notarization, Intel Macs, macOS older than 26, 16-bit and HDR editing, localization.

## 2. Facts about the machine (verified 2026-10-06)

| What | Fact | Consequence |
|---|---|---|
| System | macOS 27.0.1, Apple M5, Swift 6.4 | Build target is macOS 26+, arm64 only |
| Xcode | Not installed, only Command Line Tools 27 | Build with SwiftPM and a script, no `.xcodeproj` |
| Building without Xcode | A trial AppKit package built and its Swift Testing tests passed | Xcode is not needed for development |
| Metal without Xcode | No `metal` compiler and no `actool`; a shader compiles from source at runtime | Compile our own shaders at launch, build the icon with `iconutil` |
| Signing | Certificate `Local Dev` (Code Signing, valid until 2046) is marked untrusted, but `codesign` signs with it | The signature is stable across builds, so macOS folder permissions persist |
| Reading formats | ImageIO reads 62 types: JPEG, PNG, HEIC, AVIF, WebP, JPEG XL, GIF, TIFF, BMP, ICO, PSD, RAW | No decoders of our own |
| Animation | ImageIO returns frames and delays for both GIF and animated WebP | Playback needs no third-party library |
| Writing formats | ImageIO writes JPEG, PNG, HEIC, AVIF, GIF, TIFF, BMP, ICO, PSD, PDF. It does not write WebP or JPEG XL | WebP export needs libwebp |
| Project folder | Lives in OneDrive | Sources and git stay there; build caches, intermediates and the built app go outside OneDrive |

## 3. Stack

- **Language:** Swift 6, strict concurrency.
- **Shell:** AppKit — window, menus, mouse and trackpad events. It gives precise control over gestures and the shortest launch time.
- **Editor panels and the export dialog:** SwiftUI inside `NSHostingView`, created only on first entry into the editor. SwiftUI is not loaded on the "open and look" path.
- **Decoding and encoding:** ImageIO.
- **Rendering and effects:** Core Image on Metal, rendered into IOSurfaces that Core Animation displays directly. It provides about 200 ready filters, blend modes and GPU speed. Color management is switched off inside the renderer: pixel values pass through unchanged and the document's color space is attached on output, so blending happens on gamma-encoded values as in Paint.NET.
- **Text and shapes:** Core Text and Core Graphics.
- **Recognition:** Vision for the subject of a picture and VisionKit for Live Text. Both are system frameworks and both run only when asked for, never on the way to the first frame.
- **The only third-party dependency:** libwebp, sources as a SwiftPM C target. Used only to write WebP, still and animated.
- **Build:** SwiftPM plus `Scripts/build-app.sh`, which assembles `Pixix.app`, adds `Info.plist` and the icon, and signs with the `Local Dev` certificate. The icon is drawn by `Scripts/make-icon.swift`.
- **Tests:** Swift Testing for everything that is not UI.
- **View state:** `@Observable` models. The `@State` macro of the macOS 27 SDK needs a compiler plugin that ships only with Xcode.
- **Sandbox:** off. With it the app cannot see sibling files in the folder, and without that there is no browsing.
- **Interface language:** English only.

Rejected: Electron and Tauri (slow start, hundreds of megabytes of memory, weak gestures), pure SwiftUI (no control over scrolling and gestures, slower start), a custom renderer on bare Metal (months of work for what Core Image provides out of the box).

### Build locations

Nothing generated during a build is written inside the project folder.

| What | Where |
|---|---|
| SwiftPM build directory | `~/Library/Caches/Pixix/build` (`--scratch-path`) |
| Assembled, signed app | `~/Library/Caches/Pixix/dist/Pixix.app` |
| Installed app | `/Applications/Pixix.app`, copied by the build script on request |

## 4. Dock behavior and speed

- `applicationShouldTerminateAfterLastWindowClosed` returns `true`: closing the last window ends the process and the icon goes away.
- Cold start target: first frame within 150 ms for an ordinary JPEG. Measured on this machine: about 160 ms from process creation, for both a 4000 px and a 6000 px JPEG. The very first launch after a build takes a few hundred milliseconds longer while macOS verifies the new signature. Of the 160 ms, roughly 60 are AppKit starting up and 35 are the toolbar; the decode runs in parallel from the first moment the file name is known.
- How: no storyboard or nib, the window is created in code; decoding starts before any interface exists; the first thing shown is a frame downsampled to window size, with full resolution loaded right after; the editor, panels and libwebp are not touched until first use.
- Fallback if the cold start turns out to be noticeable: after the window closes, the process stays alive for a few minutes without a Dock icon (activation policy `.accessory`) and opens the next file instantly. Enabled only if measurements call for it, as a setting.

## 5. Code layout

```
Package.swift
Sources/
  CWebP/          libwebp, C target
  PixixCodec/     reading, writing, metadata, animation, the export pipeline
  PixixEngine/    document, layers, selection, history, rendering, painting
  Pixix/App       launch, menus, settings, diagnostics
  Pixix/Viewer    window, canvas, gestures, folder browsing, image loading
  Pixix/Export    export dialog, saving
  Pixix/Editor    editor controller, tools, inspector, dialogs
Tests/
  PixixCodecTests/
  PixixEngineTests/
Resources/        Info.plist, icon
Scripts/          build-app.sh, run.sh, make-icon.swift
```

`PixixCodec` and `PixixEngine` do not import AppKit windows and are tested without launching the app.

## 6. Viewer

**Window.** Dark background, image centered. Each picture opened from Finder gets a window of its own, a step down and to the right of the last one; opening what is already on screen brings that window forward, and a setting makes pictures share one window instead. `⌥⌘N` opens another window on the same picture. Arrows overlaid on the left and right appear when the mouse moves. Top bar: Edit, Rotate, Delete, Info, Export, Share. Bottom: zoom out, zoom in, Fit, 1:1.

**File list.** Every supported image in the folder of the opened file, sorted by name the way Finder does (`localizedStandardCompare`); sorting by date is a setting. If several files are opened from Finder at once, only those are browsed. Opening or dropping a folder browses the pictures in it. The folder is watched, so added and removed files are picked up.

**Navigation.**

| Action | How |
|---|---|
| Next and previous | `←` `→`, on-screen arrows, two-finger horizontal swipe, mouse side buttons, mouse wheel off the picture, sideways wheel |
| First and last | `Home`, `End` |
| Zoom | Pinch, `⌘+`, `⌘−`, mouse wheel over the picture |
| Fit and 100% | Double click or double tap, `⌘0`, `⌘1` |
| Pan a zoomed image | Drag, two fingers |
| Full screen | `F`, `⌃⌘F` |

The swipe versus pan conflict is resolved like this: while the whole image fits in the window, a horizontal swipe browses. When it is zoomed in, two fingers pan it, and browsing fires only on a new gesture that starts at the edge. An ordinary mouse wheel is told apart from a trackpad by `hasPreciseScrollingDeltas`: the trackpad pans and browses, and the wheel zooms while the pointer is over the picture and browses everywhere else — over the background, the arrows and the thumbnail strip. A sideways wheel always browses. While the wheel keeps turning in one spot it keeps doing what it started with, because zooming out and turning the page both change what is under the pointer.

One notch of the wheel is one fixed step, whatever the speed of the wheel: the levels are evenly spaced inside each doubling (50, 60 … 100, 120 … 200), and the fitted size is a stop on the way through. The first side button of a mouse goes to the next image and the second to the previous one, anywhere in the window.

**Browsing speed.** Decoding happens off the main thread and is cancelled when flipping quickly. Neighbors within ±2 files are preloaded. The cache has a memory limit.

**Animation.** GIF, APNG, animated WebP, HEIC and AVIF play with their native delays. `Space` pauses, `,` and `.` step frame by frame. Frames are decoded ahead in a ring buffer rather than all at once, so a long GIF does not eat memory.

**File actions.** Rotation without re-encoding where the format allows it (the orientation tag is changed). Delete to Trash with `⌘⌫` and `Delete`, rename with `F2`, duplicate, copy to a folder and move to a folder; all of them can be undone, and the folder last used is offered again, which is what sorting a shoot needs. Copy image with `⌘C`. Info with `⌘I`: a histogram, dimensions, file size, format, date, camera, color profile, and the coordinates with a button that opens the place in Maps. Show in Finder, Set as Wallpaper, Print. A right click on the picture brings up the same commands.

**Live Text.** Text in a picture can be selected with the mouse and copied; links, addresses and QR codes in it work as they do in Preview. Recognition and the selection are the system's (VisionKit). It starts a moment after a picture has settled at full size, never before the first frame, and is cancelled when flipping on. Clicks that are not on text go to the picture as before. `⇧⌘T` turns it off.

**Default app.** `Info.plist` declares the image types. Installing with `build-app.sh --install` makes Pixix the default for every type it reads, through `NSWorkspace.setDefaultApplication`; Settings has the same as a button. The apps displaced are saved, and one command or button hands the types back. That direction is not silent: macOS asks for confirmation once per file type.

## 7. Export and conversion

One dialog, opened with `⌘⇧E`:

- **Format:** JPEG, PNG, WebP, HEIC, AVIF, TIFF, GIF, BMP.
- **Size:** pixels, percent, or presets by long edge (1280, 1920, 2560). An aspect lock; unlocked means stretching.
- **Quality:** a slider, plus a "no larger than N KB" mode where quality is found automatically.
- **Output file size** is shown live: encoding runs in the background on every settings change.
- **Other:** strip metadata and location, convert to sRGB, background color when saving a transparent image as JPEG.
- **Destination:** next to the original (a number is appended if the name is taken), or a chosen location.
- **Presets:** saved sets of settings. `⌘E` repeats the last export with no dialog — that is the "one click".

Animated files convert with frames preserved: GIF ↔ WebP ↔ APNG, with resizing applied to all frames.

Later: batch conversion of several selected files.

## 8. Editor

One engine and two levels of interface. Under the hood the document is always layered; an ordinary photo is a document with one layer.

### 8.1. Quick edits

The Edit button turns the viewer window into the editor: a tool strip on the left, and on the right one panel with the tool's options, the layer's properties, adjustment sliders, layers and history.

- **Crop:** free frame, fixed ratios (original, 1:1, 4:3, 3:2, 16:9 and their portrait versions), custom ratio, straighten, flip, rotate by 90°. The frame can be dragged beyond the image, which extends the canvas.
- **Resize:** proportional or stretched.
- **Adjust:** brightness, exposure, contrast, highlights, shadows, saturation, vibrance, temperature, tint, sharpness, vignette.
- **Filters:** presets of the same parameters.
- **Markup:** arrow, line, rectangle, ellipse, text, speech bubble, numbered badge, pen, highlighter, blur region, pixelate region, spotlight. Text and shapes can cast a shadow. Each click of the badge tool adds the next number. A speech bubble is text with a filled box and a tail whose tip has a handle of its own. A spotlight leaves its area alone and darkens the rest; several spotlights are applied together, so one does not darken another.
- **Typing on the canvas.** Text is typed where it stands. The letters are drawn by the document as always; the keyboard goes to a text view nobody sees, which brings input methods, word movement and the clipboard, and its text and selection are mirrored onto the layer, where the caret and the selection are drawn from the same Core Text layout that draws the letters.

### 8.2. Document model

- **Canvas:** size, the color space of the opened picture, 8 bits per channel, at most 16384 px per side.
- **Layers:**
  - raster — premultiplied BGRA pixels in one IOSurface per layer, shared by Core Graphics (painting on the CPU) and Core Image (compositing on the GPU);
  - object — text, shape, arrow; stays editable until explicitly rasterized;
  - effect region — blurs or pixelates everything beneath it, or as a spotlight darkens everything around it; also stays an object and can be moved.
- **Every layer has:** an affine transform into document space, opacity, blend mode, visibility, lock, adjustment sliders and a filter preset. Because placement is a transform, crop, resize, rotate, flip and canvas size only rewrite transforms and never resample pixels. A layer is baked to canvas-sized pixels the first time it is painted on.
- **Selection:** a mask. Rectangle, ellipse, lasso, magic wand; add, subtract, intersect; feather. Tools and effects act within the selection. Select Subject fills the mask with what the picture is of, found by the system (Vision); Remove Background keeps only that part of a layer.
- **History:** a list of operations with a panel, as in Paint.NET. The document state is a value whose copies share pixel storage, so most operations are recorded as a pair of states. Brush strokes and fills, which change pixels in place, store the changed rectangle before and after, compressed. Consecutive changes from one slider or handle drag merge into one step. The list is capped at 300 steps and 3 GB; the oldest steps are dropped.

This is a deliberate improvement over Paint.NET, where text and shapes turn into pixels as soon as they are committed.

### 8.3. Rendering

Layers are assembled into a Core Image chain and rendered into a document-sized IOSurface, which Core Animation scales and pans. Two surfaces alternate, because Core Animation only notices new contents. A brush stroke re-renders only the rectangle it touched. Above 400% zoom, pixels are drawn unsmoothed. The selection outline is computed on the GPU at screen resolution from the mask itself, so it works for any selection shape. Flood fill and the magic wand run on the CPU as a scanline fill; no custom Metal shaders turned out to be needed.

### 8.4. Paint.NET parity

**First tier — the editor is not useful without these:**
- layers: add, delete, duplicate, merge down, flatten, reorder by buttons or by dragging, rename, opacity, blend modes, properties; the list shows a small picture of every raster layer;
- move and transform with a frame and handles;
- selection: rectangle, ellipse, lasso, magic wand; crop to selection;
- canvas size with anchor, image size, rotate, flip;
- brush, pencil, eraser, fill, gradient, color picker;
- text, shapes, lines, arrows;
- clipboard: paste as new layer, paste as new image, copy merged;
- dragging an image into the window creates a new layer;
- history panel.

**Second tier:**
- clone stamp, recolor;
- adjustments: curves, levels, hue and saturation, invert, black and white, sepia, posterize, auto levels;
- effects: blurs (Gaussian, motion, radial, zoom), sharpen, add noise and reduce noise, glow, vignette, red eye, distortions, emboss, edge detect, oil painting, pencil sketch;
- rulers, grid, units.

**Not planned:** plugins, the `.pdn` format, tablet pressure.

### 8.5. Saving

| Command | Shortcut | Behavior |
|---|---|---|
| Save | `⌘S` | Overwrites the original file in its own format, no dialog |
| Save As… | `⌘⇧S` | Saves a copy under a new name, location or format; the original is untouched |
| Save as Pixix Project… | `⌥⌘⇧S` | Saves a `.pixix` project with the layers intact |
| Export… | `⌘⇧E` | The conversion dialog from section 7 |

Save As and Export open the same dialog. Save As starts from the original format and size; Export starts from the last used settings.

Details of Save:

- The write is atomic: a temporary file next to the original, then a replace. A failed save never leaves a half-written original.
- The first Save of an editing session moves the file as it was to the Trash, where Put Back restores it; later Saves of the same session replace the session's own work and keep nothing. A setting turns this off. On a volume without a Trash the file is simply replaced.
- A document with layers or objects is flattened into the file. The session keeps its layers and history, so editing continues; once the window closes, only the flattened image remains. To keep layers, use Save as Pixix Project.
- Lossy formats are re-encoded at high quality. Metadata and the color profile are preserved.
- If the original is in a format that cannot be written (JPEG XL, RAW, PSD) or is an animation, Save opens Save As instead.
- After Save As from the editor, the session continues on the new file, as in any document app.
- Leaving the editor, closing the window or quitting with unsaved changes asks first.
- For a `.pixix` project, Save writes the project.

**The `.pixix` project:** a package directory with `manifest.json`, one PNG per raster layer and a flattened preview. It needs no third-party library.

### 8.6. The meme scenario

1. Open the template.
2. Drag your photo into the window or paste with `⌘V` — a new layer with a frame appears.
3. Pull the canvas downward with the crop tool.
4. Drag the photo below the template and fit it by the handles.
5. `⌘⇧S` — save as a new JPEG.

The scenario must work without the layers panel and without reading any help. This is the completion criterion for phase 4.

Steps 2–4 also exist as one command: Layer › Add Image Below (`⌥⌘B`) extends the canvas and puts the chosen picture there, scaled to the width of the canvas. Add Image to the Right does the same sideways.

## 9. Phases

Every phase ends with an app that can be used.

| Phase | Contents | Done when | Status |
|---|---|---|---|
| 0. Skeleton | Package, build and signing script, icon, git, opening a file from Finder | A double click opens an image; closing the window removes the Dock icon; cold start is measured | Done |
| 1. Viewer | Zoom, pan, browsing by every method, preloading, animation, rotate, delete, info, full screen, default app | Pixix replaces Preview in daily use | Done |
| 2. Export | Dialog, all formats, size, quality, size estimate, presets, libwebp, animation conversion | A large PNG becomes a small JPEG in two actions | Done |
| 3. Quick edits | Engine foundation: document, rendering, history. Crop, ratios, resize and stretch, sliders, filters, Save and Save As | Crop, adjust and save without leaving the viewer window | Done |
| 4. Markup and layers | Object layers, blur and pixelate regions, image layers, transform frame, canvas extension, layers panel, `.pixix` format | The meme scenario works with no hints | Done |
| 5. Raster editor | Selections, brushes, fill, gradient, clone stamp, blend modes, history panel, adjustment and effect menus | The first tier of 8.4 is covered, then the second | Done, except the items in section 12 |
| 6. Polish | Settings, thumbnail strip, slideshow, batch conversion, printing, `.pixix` previews in Finder, images above 100 MP | — | Settings, thumbnail strip, slideshow and printing done; the rest is not |

"Done" means built and checked by the unit tests and by scripted screenshots of the running app (see AGENTS.md). In 0.2.0 the viewer gained several windows, folders, file operations, a context menu, Live Text and the histogram, and the editor gained typing on the canvas, speech bubbles, badges, spotlights, shadows, Select Subject, Add Image Below and a straightened crop frame that shrinks to fit: a tilted frame is made smaller about its center until no corner is empty, unless it was pulled past the picture on purpose. Gesture feel — swipe thresholds, pinch, the hand on a real trackpad — has not been tried by a person yet.

Phases 0–2 remove the main pain. Phases 3–4 solve the meme task. Phase 5 is the largest and can be stretched out.

## 10. Risks

- **Gestures.** Separating the browsing swipe from the two-finger pan will take threshold tuning on a real trackpad.
- **Very large images.** The viewer shows anything macOS can decode. The editor refuses pictures above 16384 px on a side, and every raster layer costs width × height × 4 bytes, so a 100 MP document with several layers is heavy. Tiled storage would lift both limits.
- **Editing animation.** Frame-by-frame drawing on an animation is not planned: only resizing and conversion of all frames. Entering the editor takes the frame being shown, and Save then becomes Save As so the animation is not overwritten by a still.
- **Overwriting on Save.** `⌘S` replaces the original with no confirmation, and for JPEG that means a lossy re-encode. Mitigations are the atomic write, undo within the session, and the original left in the Trash by the first Save.
- **File order.** The sort order of a specific Finder window cannot be read without a separate permission to control Finder. We sort by name; Settings offers date and size.
- **Folder access.** On first access to Downloads, Documents, Desktop and cloud folders, macOS asks for permission — once per folder.
- **No Xcode** means no Instruments and no graphical debugger. Launch timing is measured with the `--timing` switch and `PIXIX_TRACE`, the interface is checked with scripted screenshots, debugging goes through `lldb` in the terminal.

## 11. Decisions

1. Bundle identifier: `me.fedorananin.pixix`.
2. An ordinary mouse wheel zooms over the picture and browses everywhere else.
3. `⌘S` overwrites the original; `⌘⇧S` saves a copy.
4. The interface is English only. `README` and `AGENTS.md` are English only.
5. The project and its git repository stay in OneDrive. Build caches, intermediates and the built app live under `~/Library/Caches/Pixix`.
6. The source is public under the MIT License. Releases are built by GitHub Actions, signed ad hoc and not notarized; users clear the quarantine flag with one command.

## 12. Not done

- **Batch conversion** of several selected files.
- **Finder previews for `.pixix`** projects. They need a Quick Look extension, which is an app extension target and awkward to build without Xcode. The project folder contains `preview.png`.
- **Tiled layer storage**, and with it images above 16384 px per side in the editor.
- **Recolor tool, red-eye removal, rulers, grid and units** from the second tier of 8.4.
- **A curves editor with a draggable curve.** Curves is five sliders.
- **Moving a selection outline** without its pixels, and transforming a selection.
- **Keeping the zoom while browsing**, to compare two shots at the same spot, and **HDR display** of pictures with a gain map. Both were considered and put off.
- **Trying by hand** what the scripted screenshots cannot reach: reordering layers by dragging, typing through an input method, selecting Live Text with the mouse.
- **Painting with pressure**, the `.pdn` format and plugins, as planned from the start.
- **The "stay warm" mode** from section 4. The measured cold start made it unnecessary so far.

