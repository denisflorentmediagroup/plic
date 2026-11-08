// Copyright 2026 Denis Florent Media Group SRL
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import AVKit
import PDFKit
import RelayInterface

/// Shows a received attachment in a window of Plic's own, from memory.
///
/// Quick Look only opens files, so a preview there means writing the
/// attachment out, decrypted. Here the image, PDF or video is
/// handed over as the bytes Plic already holds, and nothing reaches the disk.
///
/// The windows are never restorable. State restoration would persist what
/// they show — or, for an encrypted attachment, what decrypts it.
@MainActor
enum MediaViewer {
    enum Content {
        case image(Data)
        case pdf(PDFDocument)
        case video(InMemoryAsset)
    }

    /// The longest side an image is decoded at for viewing: enough to zoom
    /// into a photo, and a bound on what one image can cost.
    static let maximumImagePixels: CGFloat = 8_192

    /// Open viewers, held until they close.
    private static var windows: [ObjectIdentifier: ViewerWindow] = [:]

    /// Opens a viewer. Returns `false` when the content cannot be displayed.
    @discardableResult
    static func show(_ content: Content, title: String) -> Bool {
        let window = ViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)

        switch content {
        case .image(let data):
            guard let view = ZoomingImageView(data: data) else { return false }
            window.contentView = view
            window.setContentSize(fitted(view.imageSize))
            window.layoutIfNeeded()
            view.fitToWindow()

        case .pdf(let document):
            let view = PDFView()
            view.document = document
            view.autoScales = true
            view.delegate = PDFLinkGate.shared
            view.displayMode = .singlePageContinuous
            window.contentView = view
            window.setContentSize(fitted(NSSize(width: 760, height: 980)))

        case .video(let source):
            let view = AVPlayerView()
            let player = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
            view.player = player
            view.controlsStyle = .floating
            view.showsFullScreenToggleButton = true
            window.contentView = view
            window.setContentSize(fitted(NSSize(width: 960, height: 540)))
            window.retained = source
            window.onClose = {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            player.play()
        }

        let id = ObjectIdentifier(window)
        windows[id] = window
        window.onCloseCleanup = { windows[id] = nil }
        window.center()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// `size`, scaled down to fit comfortably on the current screen.
    private static func fitted(_ size: NSSize) -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1_440, height: 900)
        let limit = NSSize(width: visible.width * 0.85, height: visible.height * 0.85)
        let scale = min(1, limit.width / max(size.width, 1), limit.height / max(size.height, 1))
        return NSSize(
            width: max(360, (size.width * scale).rounded()),
            height: max(240, (size.height * scale).rounded())
        )
    }
}

// MARK: - Window

/// A viewer window: Esc closes it, as it closes Quick Look.
final class ViewerWindow: NSWindow {
    /// Whatever must live as long as the window — the in-memory video source,
    /// whose resource loader only holds it weakly.
    var retained: AnyObject?
    var onClose: (() -> Void)?
    fileprivate var onCloseCleanup: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func close() {
        onClose?()
        onClose = nil
        retained = nil
        super.close()
        onCloseCleanup?()
        onCloseCleanup = nil
    }
}

// MARK: - Image

/// An image in a scroll view that zooms with the trackpad, keyboard or menu,
/// centred while it is smaller than the window.
private final class ZoomingImageView: NSScrollView {
    let imageSize: NSSize
    private let imageView: NSImageView

    init?(data: Data) {
        // Animate only what can be animated safely; decode everything else no
        // larger than it can usefully be viewed.
        let image: NSImage?
        if ImageDecoding.isAnimated(data), ImageDecoding.canAnimate(data) {
            image = NSImage(data: data)
        } else {
            image = ImageDecoding.thumbnail(from: data, maxPixelSize: MediaViewer.maximumImagePixels)
        }
        guard let image else { return nil }

        imageSize = image.size
        imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true

        super.init(frame: NSRect(origin: .zero, size: image.size))
        contentView = CenteringClipView()
        documentView = imageView
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 8
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
    }

    required init?(coder: NSCoder) { nil }

    /// Shrinks the image to fit, never enlarging one that already fits: a
    /// small image blown up past 100% only shows its pixels.
    func fitToWindow() {
        let visible = contentView.bounds.size
        if imageSize.width > visible.width || imageSize.height > visible.height {
            magnify(toFit: imageView.frame)
        } else {
            magnification = 1
        }
    }
}

/// Keeps a document smaller than the visible area in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Routes links clicked in a received PDF through the link policy.
///
/// Left to itself PDFKit opens any link annotation, whatever its scheme, so
/// the policy applied to message text would not apply here — and an
/// annotation can cover the whole page.
private final class PDFLinkGate: NSObject, PDFViewDelegate {
    static let shared = PDFLinkGate()

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard LinkPolicy.opensOutside(url) else { return }
        NSWorkspace.shared.open(url)
    }
}
