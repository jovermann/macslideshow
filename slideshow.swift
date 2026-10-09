#!/usr/bin/swift
// Copyright (c) 2026 Johannes Overmann
// Distributed under the Boost Software License, Version 1.0.
// See https://www.boost.org/LICENSE_1_0.txt

import AppKit
import AVKit
import Darwin
import Foundation
import ImageIO

private let slideshowVersion = "0.1.2"
private let slideshowVersionLine = "slideshow version \(slideshowVersion) *** Copyright (c) 2026 Johannes Overmann *** https://github.com/jovermann/macslideshow"

private struct Options {
    var interval = 5.0
    var once = false
    var verbose = false
    var text: String?
    var noText = false
    var paths: [String] = []
}

private enum MediaKind {
    case image
    case video
}

private struct MediaItem {
    let url: URL
    let kind: MediaKind
}

// Print command-line help or an error, then end the process.
private func finish(_ message: String? = nil, status: Int32 = 0) -> Never {
    if let message {
        fputs("slideshow: \(message)\n", stderr)
    }
    let stream = status == 0 ? stdout : stderr
    fputs("slideshow: Fullscreen slideshow for macOS.\n\n", stream)
    fputs("Usage: slideshow [OPTIONS] FILE_OR_DIR...\n\n", stream)
    fputs("Images use the interval; AVI and MP4 videos play to their end.\n\n", stream)
    fputs("Options:\n", stream)
    fputs("  -i --interval SECONDS    Seconds per image; videos play to their end. (default=5)\n", stream)
    fputs("  -t --text TEXT           Show this text on every image or video.\n", stream)
    fputs("  -n --no-text             Start with both labels hidden.\n", stream)
    fputs("     --once                Stop after displaying every image once.\n", stream)
    fputs("  -v --verbose             Print images as they are displayed.\n", stream)
    fputs("  -h --help                Print this help message and exit.\n", stream)
    fputs("     --version             Print version and exit.\n", stream)
    fputs("\n \(slideshowVersionLine)\n", stream)
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
        } else if !pathsOnly && argument == "--version" {
            puts(slideshowVersionLine)
            exit(0)
        } else if !pathsOnly && argument == "--once" {
            options.once = true
        } else if !pathsOnly && (argument == "-n" || argument == "--no-text") {
            options.noText = true
        } else if !pathsOnly && (argument == "-v" || argument == "--verbose") {
            options.verbose = true
        } else if !pathsOnly && (argument == "-t" || argument == "--text" || argument.hasPrefix("--text=")) {
            let value: String
            if argument.hasPrefix("--text=") {
                value = String(argument.dropFirst("--text=".count))
            } else {
                index += 1
                guard index < arguments.count else { finish("missing text", status: 2) }
                value = arguments[index]
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish("text must contain visible characters", status: 2)
            }
            options.text = value
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

    if options.noText && options.text != nil { finish("--text and --no-text cannot be combined", status: 2) }
    if options.paths.isEmpty { finish("provide at least one file or directory", status: 2) }
    return options
}

// Recursively gather images and videos, ignoring unrelated and unreadable images.
private func findMedia(in paths: [String]) -> [MediaItem] {
    let imageExtensions: Set<String> = ["bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
    let videoExtensions: Set<String> = ["avi", "mp4"]
    let fileManager = FileManager.default
    var media: [MediaItem] = []

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

        for candidate in candidates {
            var candidateIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &candidateIsDirectory),
                  !candidateIsDirectory.boolValue else { continue }
            let fileExtension = candidate.pathExtension.lowercased()
            if imageExtensions.contains(fileExtension) {
                if let image = NSImage(contentsOf: candidate), image.isValid {
                    media.append(MediaItem(url: candidate, kind: .image))
                }
            } else if videoExtensions.contains(fileExtension) {
                media.append(MediaItem(url: candidate, kind: .video))
            }
        }
    }
    return media
}

// Read the original capture date and time from image metadata, when available.
private func captureDateTime(for url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
        return nil
    }
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    let values = [
        exif?[kCGImagePropertyExifDateTimeOriginal as String],
        exif?[kCGImagePropertyExifDateTimeDigitized as String],
        tiff?[kCGImagePropertyTIFFDateTime as String],
    ]
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.isLenient = false
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")

    for value in values {
        guard let raw = value as? String else { continue }
        let datePart = String(raw.prefix(10)).replacingOccurrences(of: "-", with: ":")
        if raw.count >= 16, let separator = raw.dropFirst(10).first,
           separator == " " || separator == "T" {
            let timePart = String(raw.dropFirst(11).prefix(5))
            parser.dateFormat = "yyyy:MM:dd HH:mm"
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            if let dateTime = parser.date(from: "\(datePart) \(timePart)") {
                return formatter.string(from: dateTime)
            }
        }
        parser.dateFormat = "yyyy:MM:dd"
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = parser.date(from: datePart) {
            return formatter.string(from: date)
        }
    }
    return nil
}

// Let the borderless slideshow window receive keyboard controls.
private final class SlideshowWindow: NSWindow {
    // A borderless window must explicitly accept keyboard focus.
    override var canBecomeKey: Bool { true }
}

// Draw centered white Arial text with a dark outline and shadow over the image.
private final class TextOverlayView: NSView {
    private var caption = ""
    private var details: [String] = []
    private var captionVisible = true
    private var detailsVisible = true
    private var helpVisible = false
    private var paused = false
    private var intervalNotice: String?

    // Set the initial label visibility from --no-text.
    func setTextVisible(_ visible: Bool) {
        captionVisible = visible
        detailsVisible = visible
        needsDisplay = true
    }

    // Toggle the main caption without changing the current slide timer.
    func toggleCaption() {
        captionVisible.toggle()
        needsDisplay = true
    }

    // Toggle the picture number, filename, and date.
    func toggleInfo() {
        detailsVisible.toggle()
        needsDisplay = true
    }

    // Toggle the keyboard guide in the upper-left corner.
    func toggleHelp() {
        helpVisible.toggle()
        needsDisplay = true
    }

    // Show the upper-right pause indicator only while playback is stopped.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        needsDisplay = true
    }

    // Show the changed slide interval until the controller clears it.
    func showInterval(_ interval: TimeInterval) {
        intervalNotice = String(format: "%gs", interval)
        needsDisplay = true
    }

    // Remove the temporary interval notice after three seconds.
    func hideInterval() {
        intervalNotice = nil
        needsDisplay = true
    }

    // Replace both labels together so each slide needs one redraw.
    func update(caption: String, details: [String]) {
        self.caption = caption
        self.details = details
        needsDisplay = true
    }

    // Draw the caption at a fixed margin and the optional corner overlays.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard (captionVisible && !caption.isEmpty) ||
                (detailsVisible && !details.isEmpty) || helpVisible || paused ||
                intervalNotice != nil else { return }

        let width = bounds.width * 0.9
        let maxHeight = bounds.height * 0.6
        var size = max(16, round(min(bounds.width, bounds.height) * 0.05))
        let captionStyle = NSMutableParagraphStyle()
        captionStyle.alignment = .center
        captionStyle.lineBreakMode = .byCharWrapping

        while size > 1 {
            let font = NSFont(name: "Arial", size: size)!
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: captionStyle,
            ]
            let measured = (caption as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes)
            if measured.height <= maxHeight { break }
            size -= 1
        }

        let detailFont = NSFont(name: "Arial", size: max(5, round(size / 3)))!
        let detailStyle = NSMutableParagraphStyle()
        detailStyle.alignment = .right
        detailStyle.lineBreakMode = .byTruncatingMiddle
        let lineHeight = ceil(detailFont.ascender - detailFont.descender + detailFont.leading) + 2
        let detailBottom = bounds.height * 0.015
        let detailWidth = bounds.width * 0.55
        let detailX = bounds.width - detailWidth - bounds.width * 0.02
        let margin = bounds.height * 0.04

        let font = NSFont(name: "Arial", size: size)!
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: captionStyle,
        ]
        let measured = (caption as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)
        let rect = NSRect(x: (bounds.width - width) / 2, y: margin,
                          width: width, height: min(ceil(measured.height), maxHeight))
        if captionVisible {
            drawOutlinedText(caption, font: font, paragraph: captionStyle, in: rect)
        }

        if detailsVisible {
            for (position, line) in details.reversed().enumerated() {
                let detailRect = NSRect(x: detailX, y: detailBottom + CGFloat(position) * lineHeight,
                                        width: detailWidth, height: lineHeight)
                drawOutlinedText(line, font: detailFont, paragraph: detailStyle, in: detailRect)
            }
        }

        if helpVisible {
            drawHelp()
        }

        if let intervalNotice {
            let noticeRect = NSRect(x: bounds.width * 0.66,
                                    y: bounds.height * 0.98 - lineHeight,
                                    width: bounds.width * 0.32, height: lineHeight)
            drawOutlinedText(intervalNotice, font: detailFont, paragraph: detailStyle, in: noticeRect)
        }

        if paused {
            let statusLine = intervalNotice == nil ? 1 : 2
            let pausedRect = NSRect(x: bounds.width * 0.72,
                                    y: bounds.height * 0.98 - CGFloat(statusLine) * lineHeight,
                                    width: bounds.width * 0.26, height: lineHeight)
            drawOutlinedText("paused", font: detailFont, paragraph: detailStyle, in: pausedRect)
        }
    }

    // Draw fixed key and description columns in the image's upper-left corner.
    private func drawHelp() {
        let rows = [
            ("Left / Right", "Previous / next"),
            ("Up / Home", "First image"),
            ("Space", "Pause / resume"),
            ("+ / -", "Interval +1 / -1 s"),
            ("I", "Toggle info"),
            ("T", "Toggle caption"),
            ("H", "Toggle help"),
            ("Esc / Q / Ctrl-C", "Quit"),
        ]
        let font = NSFont(name: "Arial", size: max(14, round(min(bounds.width, bounds.height) * 0.023)))!
        let keyStyle = NSMutableParagraphStyle()
        keyStyle.alignment = .right
        keyStyle.lineBreakMode = .byTruncatingTail
        let descriptionStyle = NSMutableParagraphStyle()
        descriptionStyle.alignment = .left
        descriptionStyle.lineBreakMode = .byTruncatingTail
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 5
        let inset = max(8, round(font.pointSize * 0.5))
        let gap = font.pointSize
        let textAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let keyWidth = rows.map { ($0.0 as NSString).size(withAttributes: textAttributes).width }.max() ?? 0
        let descriptionWidth = rows.map { ($0.1 as NSString).size(withAttributes: textAttributes).width }.max() ?? 0
        let panelX = bounds.width * 0.02
        let panelWidth = min(bounds.width * 0.67, keyWidth + gap + descriptionWidth + 2 * inset)
        let availableWidth = panelWidth - 2 * inset
        let keyColumnWidth = min(keyWidth, availableWidth * 0.45)
        let descriptionColumnWidth = max(0, availableWidth - keyColumnWidth - gap)
        let keyX = panelX + inset
        let descriptionX = keyX + keyColumnWidth + gap
        let top = bounds.height * 0.98
        let panel = NSRect(x: panelX, y: top - CGFloat(rows.count + 1) * lineHeight - 2 * inset,
                           width: panelWidth, height: CGFloat(rows.count + 1) * lineHeight + 2 * inset)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: panel, xRadius: inset, yRadius: inset).fill()
        let titleRect = NSRect(x: keyX, y: top - inset - lineHeight,
                               width: availableWidth, height: lineHeight)
        drawOutlinedText("slideshow \(slideshowVersion)", font: font,
                         paragraph: descriptionStyle, in: titleRect)
        for (position, row) in rows.enumerated() {
            let y = top - inset - CGFloat(position + 2) * lineHeight
            let keyRect = NSRect(x: keyX, y: y, width: keyColumnWidth, height: lineHeight)
            let descriptionRect = NSRect(x: descriptionX, y: y,
                                         width: descriptionColumnWidth, height: lineHeight)
            drawOutlinedText(row.0, font: font, paragraph: keyStyle, in: keyRect)
            drawOutlinedText(row.1, font: font, paragraph: descriptionStyle, in: descriptionRect)
        }
    }

    // Paint the black halo first, then cover the glyphs with solid white Arial.
    private func drawOutlinedText(_ text: String, font: NSFont,
                                  paragraph: NSParagraphStyle, in rect: NSRect) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black
        shadow.shadowBlurRadius = max(2, round(font.pointSize / 12))
        shadow.shadowOffset = .zero
        let darkAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .strokeColor: NSColor.black,
            .strokeWidth: -8,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ]
        let whiteAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(deviceWhite: 1, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        NSGraphicsContext.saveGraphicsState()
        NSAttributedString(string: text, attributes: darkAttributes).draw(with: rect, options: drawOptions)
        NSGraphicsContext.restoreGraphicsState()
        NSAttributedString(string: text, attributes: whiteAttributes).draw(with: rect, options: drawOptions)
    }
}

// Own the fullscreen window and advance through images and videos.
private final class Slideshow: NSObject, NSApplicationDelegate {
    private let media: [MediaItem]
    private let options: Options
    private var index = 0
    private var window: NSWindow?
    private var imageView: NSImageView?
    private var videoView: AVPlayerView?
    private var videoPlayer: AVPlayer?
    private var videoStatusObservation: NSKeyValueObservation?
    private var videoEndObserver: NSObjectProtocol?
    private var videoFailureObserver: NSObjectProtocol?
    private var textOverlay: TextOverlayView?
    private var timer: Timer?
    private var intervalNoticeTimer: Timer?
    private var keyMonitor: Any?
    private var interruptSource: DispatchSourceSignal?
    private var dateTimeCache: [URL: String] = [:]
    private var cursorHidden = false
    private var paused = false
    private var interval: TimeInterval
    private var failedVideosInRow = 0

    init(media: [MediaItem], options: Options) {
        self.media = media
        self.options = options
        self.interval = options.interval
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
        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let imageView = NSImageView(frame: contentView.bounds)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        let videoView = AVPlayerView(frame: contentView.bounds)
        videoView.autoresizingMask = [.width, .height]
        videoView.controlsStyle = .none
        videoView.videoGravity = .resizeAspect
        videoView.isHidden = true
        let overlay = TextOverlayView(frame: contentView.bounds)
        contentView.addSubview(imageView)
        contentView.addSubview(videoView)
        overlay.setTextVisible(!options.noText)
        contentView.addSubview(overlay)
        window.contentView = contentView
        textOverlay = overlay
        self.window = window
        self.imageView = imageView
        self.videoView = videoView

        signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler { NSApp.terminate(nil) }
        interruptSource.resume()
        self.interruptSource = interruptSource

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "q" ||
                (event.keyCode == 8 && event.modifierFlags.contains(.control)) {
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
                self.showCurrentItem()
            case 49 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
                self.togglePause()
            default:
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    switch event.characters {
                    case "+": self.adjustInterval(by: 1)
                    case "-", "−": self.adjustInterval(by: -1)
                    default:
                        switch event.charactersIgnoringModifiers?.lowercased() {
                        case "i": self.textOverlay?.toggleInfo()
                        case "t": self.textOverlay?.toggleCaption()
                        case "h": self.textOverlay?.toggleHelp()
                        default: return event
                        }
                    }
                } else {
                    return event
                }
            }
            return nil
        }

        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        cursorHidden = true
        showCurrentItem()
    }

    // Release the local keyboard monitor and restore the cursor on exit.
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        intervalNoticeTimer?.invalidate()
        stopVideo()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        interruptSource?.cancel()
        if cursorHidden { NSCursor.unhide() }
    }

    // Fit the overlay to the visible image or video, including letterboxing.
    private func setOverlayFrame(for size: NSSize) {
        guard let bounds = window?.contentView?.bounds else { return }
        guard size.width > 0, size.height > 0 else {
            textOverlay?.frame = bounds
            return
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        textOverlay?.frame = NSRect(x: (bounds.width - fitted.width) / 2,
                                    y: (bounds.height - fitted.height) / 2,
                                    width: fitted.width, height: fitted.height)
    }

    // Update the caption and picture information for the current item.
    private func updateText(for item: MediaItem) {
        let url = item.url
        let directory = url.deletingLastPathComponent().lastPathComponent
        if let textOverlay {
            let dateTime: String
            if item.kind == .video {
                dateTime = ""
            } else if let cached = dateTimeCache[url] {
                dateTime = cached
            } else {
                dateTime = captureDateTime(for: url) ?? ""
                dateTimeCache[url] = dateTime
            }
            var details = ["\(index + 1)/\(media.count)", url.lastPathComponent]
            if !dateTime.isEmpty { details.append(dateTime) }
            textOverlay.update(caption: options.text ?? directory.replacingOccurrences(of: "_", with: " "),
                               details: details)
        }
    }

    // Show an image for the interval or play a video through to its end.
    private func showCurrentItem() {
        timer?.invalidate()
        timer = nil
        stopVideo()
        let item = media[index]
        updateText(for: item)
        if options.verbose { fputs("\(item.url.path)\n", stderr) }

        switch item.kind {
        case .image:
            failedVideosInRow = 0
            let image = NSImage(contentsOf: item.url)
            imageView?.image = image
            imageView?.isHidden = false
            videoView?.isHidden = true
            setOverlayFrame(for: image?.size ?? .zero)
            scheduleTimer()
        case .video:
            imageView?.image = nil
            imageView?.isHidden = true
            videoView?.isHidden = false
            setOverlayFrame(for: .zero)
            playVideo(at: item.url)
        }
    }

    // Stop observing and playing the previous video before changing items.
    private func stopVideo() {
        videoStatusObservation?.invalidate()
        videoStatusObservation = nil
        if let videoEndObserver { NotificationCenter.default.removeObserver(videoEndObserver) }
        if let videoFailureObserver { NotificationCenter.default.removeObserver(videoFailureObserver) }
        videoEndObserver = nil
        videoFailureObserver = nil
        videoPlayer?.pause()
        videoView?.player = nil
        videoPlayer = nil
    }

    // Play a local movie and advance when it ends or cannot be decoded.
    private func playVideo(at url: URL) {
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        videoPlayer = player
        videoView?.player = player
        videoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
                guard let self, self.videoPlayer?.currentItem === playerItem else { return }
                self.failedVideosInRow = 0
                self.advance()
            }
        videoFailureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
                self?.skipFailedVideo(playerItem)
            }
        videoStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.videoPlayer?.currentItem === observedItem else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.setOverlayFrame(for: observedItem.presentationSize)
                    if !self.paused { self.videoPlayer?.play() }
                case .failed:
                    self.skipFailedVideo(observedItem)
                default:
                    break
                }
            }
        }
    }

    // Skip a failed movie and stop if nothing in the sequence can be played.
    private func skipFailedVideo(_ playerItem: AVPlayerItem) {
        guard videoPlayer?.currentItem === playerItem else { return }
        fputs("slideshow: cannot play video: \(media[index].url.path)\n", stderr)
        failedVideosInRow += 1
        if failedVideosInRow >= media.count {
            NSApp.terminate(nil)
        } else {
            advance()
        }
    }

    // Give a still image a fresh interval unless playback is paused.
    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard !paused, media[index].kind == .image else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.advance()
        }
    }

    // Change the interval by one second within the interactive 1...60 range.
    private func adjustInterval(by amount: TimeInterval) {
        let adjusted = min(60, max(1, interval + amount))
        guard adjusted != interval else { return }
        interval = adjusted
        if options.verbose { fputs("interval: \(interval) s\n", stderr) }
        scheduleTimer()
        textOverlay?.showInterval(interval)
        intervalNoticeTimer?.invalidate()
        intervalNoticeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.textOverlay?.hideInterval()
            self?.intervalNoticeTimer = nil
        }
    }

    // Pause immediately or resume with a full interval on the current image.
    private func togglePause() {
        paused.toggle()
        textOverlay?.setPaused(paused)
        if paused { videoPlayer?.pause() }
        else if media[index].kind == .video { videoPlayer?.play() }
        scheduleTimer()
    }

    // Move to the previous image, respecting --once at the beginning.
    private func goBack() {
        if index > 0 {
            index -= 1
        } else if !options.once {
            index = media.count - 1
        }
        showCurrentItem()
    }

    // Advance, either wrapping to the first image or ending after the final interval.
    private func advance() {
        if index + 1 == media.count {
            if options.once {
                NSApp.terminate(nil)
                return
            }
            index = 0
        } else {
            index += 1
        }
        showCurrentItem()
    }
}

private let options = parseArguments(Array(CommandLine.arguments.dropFirst()))
if NSFont(name: "Arial", size: 16) == nil {
    fputs("slideshow: Arial font is unavailable\n", stderr)
    exit(2)
}
private let media = findMedia(in: options.paths)
if media.isEmpty { finish("no supported images or videos found", status: 2) }
private let app = NSApplication.shared
private let slideshow = Slideshow(media: media, options: options)
app.setActivationPolicy(.regular)
app.delegate = slideshow
app.run()
