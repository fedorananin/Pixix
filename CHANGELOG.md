# Changelog

## 0.2.0

- **Several windows.** Each picture opened from Finder gets a window of its own, and `⌥⌘N` opens another
  window on the same picture. Settings can go back to one shared window.
- **Folders.** Opening a folder, or dropping one on the window, browses the pictures in it.
- **Live Text.** Text in a picture can be selected and copied; `⇧⌘T` turns it off.
- **File commands.** Rename (`F2`), Duplicate, Copy to Folder and Move to Folder, all undoable, and a
  right-click menu on the picture.
- **Info** shows a histogram, and a picture with a location gets an Open in Maps button.
- **Typing on the canvas.** Text is typed where it stands instead of in the side panel.
- **New markup.** Speech bubbles, numbered badges that count up by themselves, a spotlight that darkens
  everything around an area, and shadows for text and shapes.
- **Select Subject and Remove Background** find what the picture is of.
- **Add Image Below** and **Add Image to the Right** extend the canvas and put a picture there in one step.
- **Layers** can be renamed, reordered by dragging, and show a small picture of themselves.
- **Straighten** shrinks the crop frame so that no corner is left empty.
- **Save** leaves the file as it was in the Trash the first time it overwrites it in a session.

## 0.1.1

- The side buttons of a mouse browse the folder: the first goes to the next image, the second to the previous one.
- The mouse wheel zooms while the pointer is over the picture and browses everywhere else: over the
  background, the arrows and the thumbnail strip. A sideways wheel always browses.
- Wheel zoom is much gentler. One notch is one fixed step whatever the speed of the wheel
  (50 → 60 → 70 … 100 → 120 instead of 50 → 86 → 149), and zooming out stops at the fitted size on the way.

## 0.1.0

The first release.

- **Viewer.** Opens fast and quits when its window closes, so nothing lingers in the Dock. Browses the
  folder with on-screen arrows, the keyboard and a two-finger swipe. Zoom, pan, full screen, animated GIF,
  WebP and APNG, rotation without re-encoding, move to Trash with undo, file info, thumbnail strip, slideshow.
- **Export.** One dialog for format, size, quality and a file-size limit, with the resulting size shown
  live. Presets, and Export Again to repeat the last export in one keystroke. Writes JPEG, PNG, WebP, HEIC,
  AVIF, TIFF, GIF and BMP; converts animations between GIF, WebP and APNG.
- **Editor.** Layers with blend modes; crop with fixed ratios, straightening and canvas extension; text,
  arrows, shapes, blur and pixelate areas that stay editable; brush, pencil, eraser, clone stamp, paint
  bucket, gradient; rectangle, ellipse, lasso and magic wand selections; adjustment sliders, filters, and 38
  adjustments and effects with live preview; a history panel; `.pixix` projects that keep the layers.

Requires macOS 26 or later on Apple Silicon. The app is not notarized; see the README for how to open it.
