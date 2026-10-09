#!/usr/bin/swift
// Copyright (c) 2026 Johannes Overmann
// Distributed under the Boost Software License, Version 1.0.
// See https://www.boost.org/LICENSE_1_0.txt

import AppKit
import Foundation

private struct Options {
    var interval = 5.0
    var once = false
    var verbose = false
    var paths: [String] = []
}

// Print command-line help or an error, then end the process.
private func finish(_ message: String? = nil, status: Int32 = 0) -> Never {
    if let message {
        fputs("slideshow: \(message)\n", stderr)
    }
    let stream = status == 0 ? stdout : stderr
    fputs("Usage: slideshow.swift [-i SECONDS] [--once] [-v] FILE_OR_DIR ...\n", stream)
    fputs("  -i, --interval SECONDS   Seconds per image (default: 5)\n", stream)
    fputs("  --once                   Stop after displaying every image once\n", stream)
    fputs("  -v, --verbose            Print images as they are displayed\n", stream)
    fputs("  -h, --help               Show this help\n", stream)
    exit(status)
}

// Parse options while preserving the order of user-supplied paths.
private func parseArguments(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    var pathsOnly = false

    while index < arguments.count {
        let argument = arguments[index]
        if !pathsOnly && argument == "--" {
            pathsOnly = true
        } else if !pathsOnly && (argument == "-h" || argument == "--help") {
            finish()
        } else if !pathsOnly && argument == "--once" {
            options.once = true
        } else if !pathsOnly && (argument == "-v" || argument == "--verbose") {
            options.verbose = true
        } else if !pathsOnly && (argument == "-i" || argument == "--interval" || argument.hasPrefix("--interval=")) {
            let value: String
            if argument.hasPrefix("--interval=") {
                value = String(argument.dropFirst("--interval=".count))
            } else {
                index += 1
                guard index < arguments.count else { finish("missing interval", status: 2) }
                value = arguments[index]
            }
            guard let interval = Double(value), interval.isFinite, interval > 0 else {
                finish("interval must be a positive number of seconds", status: 2)
            }
            options.interval = interval
        } else if !pathsOnly && argument.hasPrefix("-") {
            finish("unknown option \(argument)", status: 2)
        } else {
            options.paths.append(argument)
        }
        index += 1
    }

    if options.paths.isEmpty { finish("provide at least one file or directory", status: 2) }
    return options
}

// Recursively gather supported images, ignoring unrelated and unreadable files.
private func findImages(in paths: [String]) -> [URL] {
    let extensions: Set<String> = ["bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
    let fileManager = FileManager.default
    var images: [URL] = []

    for path in paths {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            finish("path does not exist: \(path)", status: 2)
        }

        let candidates: [URL]
        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }
            candidates = (enumerator.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
        } else {
            candidates = [url]
        }

        for candidate in candidates where extensions.contains(candidate.pathExtension.lowercased()) {
            if let image = NSImage(contentsOf: candidate), image.isValid {
                images.append(candidate)
            }
        }
    }
    return images
}

// Let the borderless slideshow window receive keyboard controls.
private final class SlideshowWindow: NSWindow {
    // A borderless window must explicitly accept keyboard focus.
    override var canBecomeKey: Bool { true }
}

// Own the fullscreen window and advance one image on each timer tick.
private final class Slideshow: NSObject, NSApplicationDelegate {
    private let images: [URL]
    private let options: Options
    private var index = 0
    private var window: NSWindow?
    private var imageView: NSImageView?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var cursorHidden = false

    init(images: [URL], options: Options) {
        self.images = images
        self.options = options
    }

    // Create a black, borderless window covering the current display.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fputs("slideshow: no display available\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let window = SlideshowWindow(contentRect: screen.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView
        self.window = window
        self.imageView = imageView

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil
            }
            guard let self else { return event }
            switch event.keyCode {
            case 123: // Left arrow
                self.goBack()
            case 124: // Right arrow
                self.advance()
            case 126, 115: // Up arrow or Home (Pos1)
                self.index = 0
                self.showCurrentImage()
            default:
                return event
            }
            return nil
        }

        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        cursorHidden = true
        showCurrentImage()
    }

    // Release the local keyboard monitor and restore the cursor on exit.
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if cursorHidden { NSCursor.unhide() }
    }

    // Show the current image at its aspect ratio against the black background.
    private func displayCurrentImage() {
        imageView?.image = NSImage(contentsOf: images[index])
        if options.verbose { fputs("\(images[index].path)\n", stderr) }
    }

    // Show the image and give it a full interval after keyboard navigation.
    private func showCurrentImage() {
        displayCurrentImage()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: options.interval, repeats: false) { [weak self] _ in
            self?.advance()
        }
    }

    // Move to the previous image, respecting --once at the beginning.
    private func goBack() {
        if index > 0 {
            index -= 1
        } else if !options.once {
            index = images.count - 1
        }
        showCurrentImage()
    }

    // Advance, either wrapping to the first image or ending after the final interval.
    private func advance() {
        if index + 1 == images.count {
            if options.once {
                NSApp.terminate(nil)
                return
            }
            index = 0
        } else {
            index += 1
        }
        showCurrentImage()
    }
}

private let options = parseArguments(Array(CommandLine.arguments.dropFirst()))
private let images = findImages(in: options.paths)
if images.isEmpty { finish("no supported images found", status: 2) }
private let app = NSApplication.shared
private let slideshow = Slideshow(images: images, options: options)
app.setActivationPolicy(.regular)
app.delegate = slideshow
app.run()
