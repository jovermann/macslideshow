# macslideshow

A fullscreen macOS slideshow written in Swift. It uses AppKit and needs no third-party packages.
Run `./slideshow --help` for the options and `./slideshow --version` for the version and copyright line.

Build the standalone executable with `make`, then run it directly:

```sh
make
./slideshow -i 5 ~/Pictures/photo.jpg ~/Pictures/album
```

You can also run the source without building first:

```sh
swift slideshow.swift --once --interval 2 ~/Pictures/album
```

Directories are searched recursively. Supported image types are BMP, GIF, HEIC, HEIF, JPEG, PNG, TIFF, and WebP. Other files and unreadable images are silently skipped. Images from each directory are shown in path order; command-line paths retain their given order. The slideshow repeats by default. `--once` shows each image for the chosen interval and then exits.

Solid white Arial text with a separate black outline and shadow appears near the bottom of each image. By default it shows the image's parent directory name with underscores replaced by spaces. Use `-t 'My caption'` or `--text 'My caption'` to show the same custom text on every image. Smaller, right-aligned text in the bottom right uses up to three lines: picture number/total, filename, and capture date and time in `YYYY-MM-DD HH:MM` format when EXIF or TIFF metadata provides them. If only a date is available, that line shows the date alone; if no capture date is available, the line is omitted. Use `-n`/`--no-text` to hide both labels. Newlines in custom text are supported. The main text is scaled down if needed to fit the screen.

Left and Right move between images; Up or Home (Pos1) returns to the first. Press Space to pause or resume; `paused` appears in the upper right while stopped. Press + or - to change the interval by one second, limited to 1–60 seconds; the new interval appears in the upper right for three seconds. Press I to toggle the picture info, T to toggle the main caption, and H to show or hide a two-column key guide in the upper left. `--no-text` starts with both labels hidden; I and T can turn them on. Navigation or changing the interval restarts the countdown, and resuming starts a full interval for the current image. Press Escape, Q, or Control-C to quit. SIGINT from the launching terminal also quits cleanly. Use `-v` to print the image currently displayed.
