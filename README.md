# Pixix

A fast image viewer and layered editor for macOS. It opens instantly, leaves the Dock when its window closes,
flips through a folder like Windows 11 Photos, converts and resizes in one dialog, and edits with layers like
Paint.NET.

![Pixix showing a picture](docs/screenshots/viewer.jpg)

## Install

Requires macOS 26 or later on Apple Silicon.

Paste this into Terminal. It downloads the latest release into Applications, clears the flag that makes macOS
refuse apps from the internet, and opens Pixix:

```sh
curl -L https://github.com/fedorananin/Pixix/releases/latest/download/Pixix.zip -o /tmp/Pixix.zip \
  && rm -rf /Applications/Pixix.app \
  && ditto -x -k /tmp/Pixix.zip /Applications \
  && xattr -dr com.apple.quarantine /Applications/Pixix.app \
  && open /Applications/Pixix.app
```

Or by hand:

1. Download `Pixix.zip` from the [latest release](https://github.com/fedorananin/Pixix/releases/latest) and
   unpack it.
2. Move `Pixix.app` to the Applications folder.
3. Run this once in Terminal, otherwise macOS says the app cannot be verified and will not open it:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Pixix.app
   ```

4. Open Pixix.

The command is needed because Pixix is not notarized by Apple: notarization requires a paid developer account,
and this is a free hobby project. The command only removes the "downloaded from the internet" mark from this one
app. If you would rather not use Terminal, try to open the app once, then go to **System Settings › Privacy &
Security** and press **Open Anyway**.

To make Pixix open your pictures by default, go to **Pixix › Settings** and press **Open Images with Pixix**.
**Restore Previous Apps** in the same place hands the types back; macOS asks you to confirm each file type
separately, so expect a dialog per type. For a single type it is quicker to select such a file in Finder,
choose **File › Get Info**, pick the app under **Open With** and press **Change All**.

## Viewing

| Action | How |
|---|---|
| Next, previous image | `←` `→`, the on-screen arrows, a two-finger horizontal swipe, the side buttons of a mouse, the mouse wheel anywhere off the picture, a sideways wheel |
| First, last image | `Home`, `End` |
| Zoom | Pinch, the mouse wheel over the picture, `+` `−`, `⌘+` `⌘−` |
| Fit, actual size | Double click, `0` / `1`, `⌘0` / `⌘1` |
| Pan a zoomed image | Drag, or two fingers |
| Full screen | `F` |
| Play or pause an animation | `Space`; `,` and `.` step frame by frame |
| Rotate the file | `⌘R`, `⌘L` |
| Move to Trash | `⌘⌫` or `Delete`; `⌘Z` brings it back |
| Info | `⌘I` |
| Thumbnail strip | `⌥⌘T` |
| Slideshow | `⇧⌘↩` |

Opening one file browses its whole folder. Opening several browses just those.

## Saving and converting

| Command | Shortcut | What it does |
|---|---|---|
| Save | `⌘S` | Overwrites the file being edited, in its own format |
| Save As… | `⇧⌘S` | Saves a copy; the original is untouched |
| Save as Pixix Project… | `⌥⇧⌘S` | Saves a `.pixix` project that keeps the layers |
| Export… | `⇧⌘E` | Format, size, quality, with the resulting file size shown live |
| Export Again | `⌘E` | Repeats the last export next to the original, no questions |

Formats written: JPEG, PNG, WebP, HEIC, AVIF, TIFF, GIF, BMP. Animated GIF, WebP and APNG convert into each
other with all frames. Everything macOS can decode is read, including RAW, PSD and JPEG XL.

## Editing

![The Pixix editor with layers, text, an arrow and a pixelated area](docs/screenshots/editor.jpg)

Press **Edit** (`⌘↩`). The left strip holds the tools, the right panel their options, the layer's properties,
adjustment sliders, the layer list and the history.

- **Crop** (`C`): free or fixed ratio, straighten, and drag the frame past the edge to extend the canvas.
- **Markup**: arrow (`A`), line, rectangle (`R`), ellipse (`U`), pen (`P`), highlighter (`H`), text (`T`),
  blur area (`J`), pixelate area (`K`). These stay editable objects until rasterized.
- **Painting**: brush (`B`), pencil (`N`), eraser (`E`), clone stamp (`S`), paint bucket (`G`), gradient (`D`),
  color picker (`I`).
- **Selections**: rectangle (`M`), ellipse (`O`), lasso (`L`), magic wand (`W`). Shift adds, Option subtracts.
- **Layers**: drop or paste a picture to add it as a layer; move, resize and rotate it with the Move tool (`V`).
- **Image**, **Adjustments** and **Effects** menus: resize, canvas size, rotate, flip, levels, curves, blurs,
  noise, distortions and more, each with a live preview.

Hold `Space` to pan. `X` swaps the two colors. `[` and `]` change the brush size.

## Building from source

You need macOS 26 or later with Xcode 27 or its Command Line Tools (Swift 6.4). Xcode itself is optional.

```sh
git clone https://github.com/fedorananin/Pixix.git
cd Pixix
Scripts/build-app.sh             # build ~/Library/Caches/Pixix/dist/Pixix.app
Scripts/build-app.sh --install   # also copy it to /Applications and make it the default image viewer
Scripts/run.sh photo.jpg         # build, then open a picture
swift test --scratch-path ~/Library/Caches/Pixix/build
```

An app you build yourself needs no `xattr` command. `--install` also makes Pixix the default app for every
image type it reads and remembers the apps that had them; add `--keep-defaults` to skip that.
`Pixix --restore-default` undoes it, with one macOS confirmation dialog per file type.

The script signs with the certificate named in `PIXIX_SIGN_IDENTITY`, or one called `Local Dev` if your
keychain has it, or ad hoc otherwise. With an ad hoc signature macOS asks for folder access again after every
rebuild; a self-signed code signing certificate avoids that. Build output never lands in the project folder.

Every push is built and tested by [GitHub Actions](.github/workflows/build.yml). Pushing a tag such as `v0.1.0`
publishes a release with `Pixix.zip` attached.

### Layout

```
Sources/CWebP/        vendored libwebp 1.6.0, used only to write WebP
Sources/PixixCodec/   reading, writing, metadata, export
Sources/PixixEngine/  document, layers, selection, history, rendering, painting
Sources/Pixix/        the app: viewer, editor, export dialog
Tests/                Swift Testing suites for the codec and the engine
Resources/            Info.plist and the icon
Scripts/              build-app.sh, run.sh, make-icon.swift, make-sample.swift
```

[PLAN.md](PLAN.md) holds the design and what is and is not done. [AGENTS.md](AGENTS.md) holds the rules for
working on the code, including for AI coding agents.

### Diagnostics

The binary accepts a few switches when run from a terminal:

```sh
APP=~/Library/Caches/Pixix/dist/Pixix.app/Contents/MacOS/Pixix
$APP --make-default                                     # open every supported file type with Pixix
$APP --restore-default                                  # give them back; macOS asks to confirm each type
$APP --timing --quit photo.jpg                          # milliseconds to the first frame
PIXIX_TRACE=1 $APP --timing --quit photo.jpg            # the same, with launch checkpoints
$APP --snapshot out.png photo.jpg                       # a picture of the viewer window
$APP --snapshot out.png --edit --demo meme photo.jpg    # a picture of the editor after a scripted scenario
```

`swift Scripts/make-sample.swift photo.jpg` draws a sample picture to try these on.

## Author and license

Made by [Fedor Ananin](https://github.com/fedorananin). Source: <https://github.com/fedorananin/Pixix>.

Released under the [MIT License](LICENSE): use it, change it, ship it, sell it — just keep the copyright notice.
libwebp, bundled in `Sources/CWebP`, is under its own BSD-style license; see `Sources/CWebP/licenses`.
