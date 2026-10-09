# macslideshow

A fullscreen macOS slideshow written in Swift. It uses AppKit and needs no third-party packages.

Build the standalone executable once, then run it directly:

```sh
swiftc slideshow.swift -o slideshow
./slideshow -i 5 ~/Pictures/photo.jpg ~/Pictures/album
```

You can also run the source without building first:

```sh
swift slideshow.swift --once --interval 2 ~/Pictures/album
```

Directories are searched recursively. Supported image types are BMP, GIF, HEIC, HEIF, JPEG, PNG, TIFF, and WebP. Other files and unreadable images are silently skipped. Images from each directory are shown in path order; command-line paths retain their given order. The slideshow repeats by default. `--once` shows each image for the chosen interval and then exits. Left and Right move between images; Up or Home (Pos1) returns to the first. Navigation resets the interval. Press Escape or Q to quit. Use `-v` to print the image currently displayed.
