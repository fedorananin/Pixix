# Changelog

## 0.4.0

- **Color picker.** Switched on in Settings, with a shortcut of its own (`⇧⌘1`, or one of your choosing): the
  screen freezes and a magnifier follows the pointer, showing the pixels around it enlarged and the color of
  the one in the middle as HEX, RGB, HSL and HSB. The arrow keys move by a single pixel.
- **A click copies the color** in the notation you chose, or **opens a small window** with every value and a
  button to copy each; Settings says which, and a click with `⌥` held does the other.
- Settings chooses which notations are shown. The values are sRGB, whatever the display.
- Screenshots and the color picker are switched on separately; either keeps Pixix in the menu bar.
- Settings is laid out in three pages: General, Screenshots and Color Picker.

## 0.3.0

- **Screenshots.** Switched on in Settings, Pixix takes screenshots: press the shortcut (`⇧⌘2`, or one of your
  choosing), drag over a part of the screen, and copy or save it. A click takes a window, `⌘A` the display.
- **Size and proportions.** The selection shows its size in pixels. It can be held to 16 : 9 and other
  proportions, given a ready-made size, or have its width and height typed in.
- **Markup on the spot.** A small panel beside the selection draws arrows, lines, shapes, text, numbered badges
  and a highlighter, and pixelates or blurs what should not be seen, without opening a window. One click sends
  the result to the full editor with every mark still an editable layer.
- **The shortcut is yours to choose.** Settings records any key with `⌘`, `⌥` or `⌃`, or a function key,
  including the ones macOS uses for its own screenshots, and says when macOS still holds the one you picked.
- **Copy the text** in a selection with `⇧⌘C`.
- **In the menu bar.** With screenshots on, Pixix leaves the Dock when its last window closes but stays behind
  a menu bar icon, and can start at login. With the option off, closing the last window quits as before.
- An editor window on a pasted picture or a screenshot is titled "Untitled" and shows its size.

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
