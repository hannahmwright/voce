#if os(macOS)
import AppKit
import ApplicationServices
import CoreImage
import QuartzCore

// MARK: - NSBezierPath → CGPath

private extension NSBezierPath {
    var cgPathFallback: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let kind = element(at: i, associatedPoints: &points)
            switch kind {
            case .moveTo:  path.move(to: points[0])
            case .lineTo:  path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            @unknown default: break
            }
        }
        return path
    }
}

@MainActor
public final class MacOverlayPresenter: NSObject, OverlayPresenter {
    private enum LayoutMode {
        case compact
        case transcript
    }

    private enum PulseMode {
        case none
        case listening
        case transcribing
    }

    private static let axSelectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let axBoundsForTextMarkerRangeParameterizedAttribute = "AXBoundsForTextMarkerRange"
    private static let compactSize = TranscriptOverlayLayout.compactSize
    private static let transcriptSize = TranscriptOverlayLayout.maximumTranscriptSize
    private static let windowPadding: CGFloat = 48

    public struct AnchorSnapshot: Sendable, Equatable {
        public let frame: CGRect

        public init(frame: CGRect) {
            self.frame = frame
        }
    }

    private var window: NSWindow?
    private var containerView: NSView?
    private var glassHostView: NSView?
    private var backgroundImageLayer: CALayer?
    private var revealedBackgroundImageLayer: CALayer?
    private var scrimLayer: CAGradientLayer?
    private var auraPrimaryLayer: CAGradientLayer?
    private var auraSecondaryLayer: CAGradientLayer?
    private var glassTintLayer: CAGradientLayer?
    private var sheenLayer: CAGradientLayer?
    private var statusTextField: NSTextField?
    private var transcriptScrollView: NSScrollView?
    private var transcriptTextView: NSTextView?
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var wasHidden = true
    private var anchorSnapshot: AnchorSnapshot?
    private var layoutMode: LayoutMode = .compact
    private var activePulseMode: PulseMode = .none
    private var hasShownLiveTranscriptInSession = false
    private var currentBubbleSize: NSSize = TranscriptOverlayLayout.compactSize
    private var lastLiveTranscriptText: String = ""
    private var transcriptBubbleHeight: CGFloat = TranscriptOverlayLayout.minimumTranscriptHeight
    private var sessionPinnedOrigin: NSPoint?
    private var userDraggedPosition: NSPoint?
    private var isPositioningProgrammatically = false
    private var userDidDrag = false
    private var repositionModeEnabled = false
    private var repositionModeTask: Task<Void, Never>?

    /// Called when the user finishes dragging the overlay to a new position.
    /// Provides the window origin so the caller can persist it per-app.
    public var onUserDraggedToPosition: ((NSPoint) -> Void)?

    // Monet-inspired palette matching the app's DesignSystem.
    private static let accentBlue = NSColor(red: 0.32, green: 0.60, blue: 0.82, alpha: 1.0)    // cerulean
    private static let accentCyan = NSColor(red: 0.62, green: 0.78, blue: 0.90, alpha: 1.0)    // sky blue
    private static let accentLavender = NSColor(red: 0.72, green: 0.70, blue: 0.84, alpha: 1.0) // lavender haze
    private static let accentWheat = NSColor(red: 0.82, green: 0.74, blue: 0.52, alpha: 1.0)   // golden wheat
    private static let compactCornerRadius: CGFloat = 26
    private static let transcriptCornerRadius: CGFloat = 30
    private static let initialTranscriptShellHeight: CGFloat = 78

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
            repositionModeTask?.cancel()
            repositionModeTask = nil
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }

    /// Pre-create the overlay window so the first `show` has no lazy-init stutter.
    public func prepareWindow() {
        ensureWindow()
    }

    public func captureAnchorSnapshot() -> AnchorSnapshot? {
        guard AXIsProcessTrusted(),
              let frame = currentFocusedFrame() else {
            return nil
        }

        return AnchorSnapshot(frame: frame)
    }

    public func setAnchorSnapshot(_ snapshot: AnchorSnapshot?) {
        anchorSnapshot = snapshot
    }

    /// Restores a previously saved drag position so the overlay appears
    /// where the user last placed it for this app.
    public func restoreDraggedPosition(_ origin: NSPoint) {
        userDraggedPosition = origin
        sessionPinnedOrigin = origin
    }

    public func beginInteractiveRepositionMode(timeout: TimeInterval = 10) {
        ensureWindow()
        guard let window else { return }
        repositionModeTask?.cancel()
        repositionModeEnabled = true
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = true

        repositionModeTask = Task { @MainActor [weak self] in
            let delay = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            self?.endInteractiveRepositionMode()
        }
    }

    public func show(state: OverlayState) {
        ensureWindow()

        let isFirstShow = wasHidden
        wasHidden = false

        switch state {
        case .listening(let handsFree, _):
            applyDefaultSurfaceAppearance()
            listeningHandsFree = handsFree
            listeningStartDate = Date()
            lastLiveTranscriptText = ""
            hasShownLiveTranscriptInSession = false
            resetTranscriptBubbleGrowth()
            transcriptBubbleHeight = max(transcriptBubbleHeight, Self.initialTranscriptShellHeight)
            updateTranscript("Transcribing…", preserveBubbleShell: true)
            stopTimer()
            animateAura(color: Self.accentBlue)
            resetBorderToAccent()
            startDotPulse()

        case .liveTranscript(let text, _):
            applyDefaultSurfaceAppearance()
            stopTimer()
            lastLiveTranscriptText = text
            updateTranscript(text, preserveBubbleShell: !hasShownLiveTranscriptInSession)
            hasShownLiveTranscriptInSession = true
            animateAura(color: Self.accentBlue)
            resetBorderToAccent()
            startDotPulse()

        case .transcribing:
            stopTimer()
            applyContinuousBubbleLayout()
            hideContent()
            resetBorderToAccent()
            applyTranscribingSurfaceAppearance()
            startTranscribingPulse()

        case .inserted:
            applyDefaultSurfaceAppearance()
            applyContinuousBubbleLayout()
            stopTimer()
            stopDotPulse()
            updateText("Inserted")
            resetBorderToAccent()
            playSuccessBounce()

        case .copiedOnly:
            applyDefaultSurfaceAppearance()
            applyContinuousBubbleLayout()
            stopTimer()
            stopDotPulse()
            updateText("Copied to clipboard")
            resetBorderToAccent()

        case .failure(let message):
            applyDefaultSurfaceAppearance()
            applyContinuousBubbleLayout()
            stopTimer()
            stopDotPulse()
            updateText("Error: \(message)")
            animateAura(color: .systemRed)
            updateBorderColors(for: .systemRed)
        }

        positionWindow()

        if isFirstShow && !reduceMotion {
            // Entrance animation: fade in + slide up + gentle scale
            window?.alphaValue = 0
            let finalOrigin = window?.frame.origin ?? .zero
            isPositioningProgrammatically = true
            window?.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 12))
            containerView?.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            window?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // spring-like
                self.window?.animator().alphaValue = 1
                self.window?.animator().setFrameOrigin(finalOrigin)
            } completionHandler: {
                Task { @MainActor [weak self] in
                    self?.isPositioningProgrammatically = false
                }
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
            containerView?.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        } else {
            isPositioningProgrammatically = false
            window?.alphaValue = 1
            window?.orderFrontRegardless()
        }
    }

    public func popAndHide() {
        stopTimer()
        stopDotPulse()
        wasHidden = true
        anchorSnapshot = nil
        lastLiveTranscriptText = ""
        hasShownLiveTranscriptInSession = false
        sessionPinnedOrigin = nil
        resetTranscriptBubbleGrowth()
        endInteractiveRepositionMode(notify: false)
        notifyDragIfNeeded()
        userDraggedPosition = nil

        guard !reduceMotion else {
            window?.orderOut(nil)
            return
        }

        // Pop: scale up + fade out simultaneously
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
        containerView?.layer?.transform = CATransform3DMakeScale(1.08, 1.08, 1)
        containerView?.layer?.opacity = 0
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            self.window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.window?.orderOut(nil)
                self?.containerView?.layer?.transform = CATransform3DIdentity
                self?.containerView?.layer?.opacity = 1
            }
        })
    }

    public func hide() {
        stopTimer()
        stopDotPulse()
        wasHidden = true
        anchorSnapshot = nil
        lastLiveTranscriptText = ""
        hasShownLiveTranscriptInSession = false
        sessionPinnedOrigin = nil
        resetTranscriptBubbleGrowth()
        endInteractiveRepositionMode(notify: false)
        notifyDragIfNeeded()
        userDraggedPosition = nil

        if !reduceMotion {
            // Exit: fade out + subtle scale down + slide down
            let currentOrigin = window?.frame.origin ?? .zero

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
            containerView?.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
            CATransaction.commit()

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.window?.animator().alphaValue = 0
                self.window?.animator().setFrameOrigin(NSPoint(x: currentOrigin.x, y: currentOrigin.y - 6))
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.window?.orderOut(nil)
                    self?.containerView?.layer?.transform = CATransform3DIdentity
                }
            })
        } else {
            window?.orderOut(nil)
        }
    }

    private func ensureWindow() {
        if window != nil {
            return
        }

        let contentRect = NSRect(origin: .zero, size: windowSize(for: Self.compactSize))
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let canvas = NSView(frame: contentRect)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.clear.cgColor

        let bubbleRect = CGRect(
            x: Self.windowPadding,
            y: Self.windowPadding,
            width: Self.compactSize.width,
            height: Self.compactSize.height
        )

        let container = NSView(frame: bubbleRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.compactCornerRadius
        container.layer?.masksToBounds = false
        self.containerView = container

        // Soft atmospheric glow behind the pill.
        let auraPrimary = CAGradientLayer()
        auraPrimary.type = .radial
        auraPrimary.colors = [
            Self.accentBlue.withAlphaComponent(0.22).cgColor,
            Self.accentLavender.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor
        ]
        auraPrimary.locations = [0, 0.55, 1]
        auraPrimary.startPoint = CGPoint(x: 0.5, y: 0.5)
        auraPrimary.endPoint = CGPoint(x: 1, y: 1)
        auraPrimary.frame = CGRect(x: -44, y: -22, width: bubbleRect.width + 88, height: bubbleRect.height + 62)
        auraPrimary.opacity = 0.70
        container.layer?.addSublayer(auraPrimary)
        self.auraPrimaryLayer = auraPrimary

        let auraSecondary = CAGradientLayer()
        auraSecondary.type = .radial
        auraSecondary.colors = [
            Self.accentCyan.withAlphaComponent(0.16).cgColor,
            Self.accentBlue.withAlphaComponent(0.05).cgColor,
            NSColor.clear.cgColor
        ]
        auraSecondary.locations = [0, 0.5, 1]
        auraSecondary.startPoint = CGPoint(x: 0.5, y: 0.5)
        auraSecondary.endPoint = CGPoint(x: 1, y: 1)
        auraSecondary.frame = CGRect(x: 12, y: -36, width: bubbleRect.width * 0.78, height: bubbleRect.height + 74)
        auraSecondary.opacity = 0.60
        container.layer?.addSublayer(auraSecondary)
        self.auraSecondaryLayer = auraSecondary

        // Glass surface: frosted background image + translucent tint.
        let glassHost = NSView(frame: NSRect(origin: .zero, size: Self.compactSize))
        glassHost.wantsLayer = true
        glassHost.layer?.cornerRadius = Self.compactCornerRadius
        glassHost.layer?.masksToBounds = true
        glassHost.layer?.borderWidth = 0.5
        glassHost.layer?.borderColor = NSColor.white.withAlphaComponent(0.50).cgColor

        // Background painting — blurred, bright, airy like the app window.
        let imageLayer = CALayer()
        if let cgImage = Self.loadBlurredBackgroundImage() {
            imageLayer.contents = cgImage
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.minificationFilter = .trilinear
            imageLayer.magnificationFilter = .trilinear
            imageLayer.opacity = 0.70
        }
        imageLayer.frame = glassHost.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glassHost.layer?.addSublayer(imageLayer)
        self.backgroundImageLayer = imageLayer

        let revealedImageLayer = CALayer()
        if let cgImage = Self.loadBackgroundCGImage() {
            revealedImageLayer.contents = cgImage
            revealedImageLayer.contentsGravity = .resizeAspectFill
            revealedImageLayer.minificationFilter = .trilinear
            revealedImageLayer.magnificationFilter = .trilinear
            revealedImageLayer.opacity = 0.0
        }
        revealedImageLayer.frame = glassHost.bounds
        revealedImageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glassHost.layer?.addSublayer(revealedImageLayer)
        self.revealedBackgroundImageLayer = revealedImageLayer

        // Light frosted scrim — white/cream, heavier in center for readability,
        // fading at edges so the painting peeks through like the app window.
        let scrimLayer = CAGradientLayer()
        scrimLayer.type = .radial
        scrimLayer.colors = [
            NSColor.white.withAlphaComponent(0.82).cgColor,
            NSColor.white.withAlphaComponent(0.62).cgColor,
            NSColor.white.withAlphaComponent(0.35).cgColor
        ]
        scrimLayer.locations = [0, 0.5, 1]
        scrimLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        scrimLayer.endPoint = CGPoint(x: 1, y: 1)
        scrimLayer.frame = glassHost.bounds
        scrimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glassHost.layer?.addSublayer(scrimLayer)
        self.scrimLayer = scrimLayer

        // Warm colored tint — subtle wheat & sky like the app backdrop.
        let glassTint = CAGradientLayer()
        glassTint.colors = [
            Self.accentCyan.withAlphaComponent(0.06).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            Self.accentWheat.withAlphaComponent(0.10).cgColor
        ]
        glassTint.startPoint = CGPoint(x: 0, y: 1)
        glassTint.endPoint = CGPoint(x: 1, y: 0)
        glassTint.frame = glassHost.bounds
        glassTint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glassHost.layer?.addSublayer(glassTint)
        self.glassTintLayer = glassTint

        // Bright top-edge sheen for glass depth.
        let sheen = CAGradientLayer()
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.50).cgColor,
            NSColor.white.withAlphaComponent(0.12).cgColor,
            NSColor.clear.cgColor
        ]
        sheen.locations = [0, 0.25, 1]
        sheen.startPoint = CGPoint(x: 0.1, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.9, y: 0.0)
        sheen.frame = glassHost.bounds
        sheen.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glassHost.layer?.addSublayer(sheen)
        self.sheenLayer = sheen

        // Soft natural shadow — not colored, just depth.
        container.layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        container.layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.layer?.shadowRadius = 18
        container.layer?.shadowOpacity = 1.0

        self.glassHostView = glassHost
        container.addSubview(glassHost)
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glassHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glassHost.topAnchor.constraint(equalTo: container.topAnchor),
            glassHost.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Compact status text.
        let label = NSTextField(labelWithString: "Listening 00:00")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.20, alpha: 0.85)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.shadow = textShadow
        label.translatesAutoresizingMaskIntoConstraints = false
        glassHost.addSubview(label)
        self.statusTextField = label

        // Transcript preview grows to three wrapped lines and follows the latest partials.
        let transcriptTextView = NSTextView(frame: .zero)
        transcriptTextView.drawsBackground = false
        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = false
        transcriptTextView.isVerticallyResizable = true
        transcriptTextView.isHorizontallyResizable = false
        transcriptTextView.textContainerInset = NSSize(width: 0, height: TranscriptOverlayLayout.transcriptTextInset)
        transcriptTextView.font = .systemFont(ofSize: 15, weight: .semibold)
        transcriptTextView.textColor = NSColor(calibratedWhite: 0.18, alpha: 0.88)
        transcriptTextView.alignment = .center
        transcriptTextView.textContainer?.lineBreakMode = .byWordWrapping
        transcriptTextView.textContainer?.widthTracksTextView = true

        let transcriptScrollView = NSScrollView(frame: .zero)
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.borderType = .noBorder
        transcriptScrollView.hasVerticalScroller = false
        transcriptScrollView.hasHorizontalScroller = false
        transcriptScrollView.autohidesScrollers = true
        transcriptScrollView.verticalScrollElasticity = .none
        transcriptScrollView.horizontalScrollElasticity = .none
        transcriptScrollView.documentView = transcriptTextView
        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        transcriptScrollView.isHidden = true
        glassHost.addSubview(transcriptScrollView)
        self.transcriptTextView = transcriptTextView
        self.transcriptScrollView = transcriptScrollView

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: glassHost.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: glassHost.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: glassHost.centerYAnchor),

            transcriptScrollView.leadingAnchor.constraint(equalTo: glassHost.leadingAnchor, constant: 24),
            transcriptScrollView.trailingAnchor.constraint(equalTo: glassHost.trailingAnchor, constant: -24),
            transcriptScrollView.topAnchor.constraint(equalTo: glassHost.topAnchor, constant: 16),
            transcriptScrollView.bottomAnchor.constraint(equalTo: glassHost.bottomAnchor, constant: -16)
        ])

        canvas.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: Self.windowPadding),
            container.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -Self.windowPadding),
            container.topAnchor.constraint(equalTo: canvas.topAnchor, constant: Self.windowPadding),
            container.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -Self.windowPadding)
        ])

        panel.contentView = canvas
        self.window = panel

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )

    }

    @objc private func windowDidMove(_ notification: Notification) {
        // Only treat moves as user drags during explicit reposition mode.
        guard !isPositioningProgrammatically,
              repositionModeEnabled,
              let window, window.isVisible, !wasHidden else { return }
        userDraggedPosition = window.frame.origin
        userDidDrag = true
    }

    private func animateAura(color: NSColor) {
        guard !reduceMotion else {
            applyAuraPalette(primary: color, secondary: color.blended(withFraction: 0.35, of: Self.accentLavender) ?? color)
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        applyAuraPalette(primary: color, secondary: color.blended(withFraction: 0.35, of: Self.accentLavender) ?? color)
        CATransaction.commit()
    }

    private func updateText(_ newText: String) {
        transcriptScrollView?.isHidden = true
        statusTextField?.isHidden = false
        guard !reduceMotion else {
            statusTextField?.stringValue = newText
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            self.statusTextField?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.statusTextField?.stringValue = newText
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self?.statusTextField?.animator().alphaValue = 1
                }
            }
        })
    }

    private func updateTranscript(_ text: String, preserveBubbleShell: Bool = false) {
        statusTextField?.isHidden = true
        transcriptScrollView?.isHidden = false
        let attributedText = TranscriptOverlayLayout.attributedText(
            text,
            shadow: textShadow
        )
        let textHeight = TranscriptOverlayLayout.measuredTextHeight(for: attributedText)
        let measuredBubbleSize = TranscriptOverlayLayout.bubbleSize(
            forTextHeight: textHeight,
            previousHeight: transcriptBubbleHeight
        )
        let bubbleSize: NSSize
        if preserveBubbleShell {
            let preservedHeight = max(
                currentBubbleSize.width > Self.compactSize.width ? currentBubbleSize.height : 0,
                transcriptBubbleHeight,
                Self.initialTranscriptShellHeight
            )
            bubbleSize = NSSize(
                width: TranscriptOverlayLayout.maximumTranscriptSize.width,
                height: preservedHeight
            )
        } else {
            bubbleSize = measuredBubbleSize
        }
        transcriptBubbleHeight = max(transcriptBubbleHeight, bubbleSize.height)
        applyLayout(.transcript, bubbleSize: bubbleSize)
        transcriptTextView?.textContainerInset = NSSize(
            width: 0,
            height: TranscriptOverlayLayout.transcriptTextInset
        )
        transcriptTextView?.textStorage?.setAttributedString(attributedText)
        if TranscriptOverlayLayout.shouldScrollToLatest(
            textHeight: textHeight,
            bubbleHeight: bubbleSize.height
        ) {
            transcriptTextView?.scrollToEndOfDocument(nil)
        } else {
            transcriptTextView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    private func hideContent() {
        statusTextField?.isHidden = true
        transcriptScrollView?.isHidden = true
    }

    private func applyDefaultSurfaceAppearance() {
        backgroundImageLayer?.opacity = 0.70
        revealedBackgroundImageLayer?.opacity = 0.0
        scrimLayer?.colors = [
            NSColor.white.withAlphaComponent(0.82).cgColor,
            NSColor.white.withAlphaComponent(0.62).cgColor,
            NSColor.white.withAlphaComponent(0.35).cgColor
        ]
        glassTintLayer?.colors = [
            Self.accentCyan.withAlphaComponent(0.06).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            Self.accentWheat.withAlphaComponent(0.10).cgColor
        ]
        sheenLayer?.opacity = 1.0
        glassHostView?.layer?.backgroundColor = NSColor.clear.cgColor
        glassHostView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.50).cgColor
    }

    private func applyTranscribingSurfaceAppearance() {
        backgroundImageLayer?.opacity = 0.32
        revealedBackgroundImageLayer?.opacity = 0.62
        scrimLayer?.colors = [
            NSColor.white.withAlphaComponent(0.50).cgColor,
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0.14).cgColor
        ]
        glassTintLayer?.colors = [
            Self.accentCyan.withAlphaComponent(0.08).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            Self.accentWheat.withAlphaComponent(0.11).cgColor
        ]
        sheenLayer?.opacity = 0.78
        glassHostView?.layer?.backgroundColor = NSColor.clear.cgColor
        glassHostView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.56).cgColor
    }

    private func applyLayout(_ newLayout: LayoutMode, bubbleSize requestedSize: NSSize? = nil) {
        guard let window else { return }
        let targetSize = requestedSize ?? (newLayout == .transcript ? Self.transcriptSize : Self.compactSize)
        guard layoutMode != newLayout || currentBubbleSize != targetSize else {
            if newLayout == .transcript {
                statusTextField?.isHidden = true
                transcriptScrollView?.isHidden = false
            } else {
                statusTextField?.isHidden = false
                transcriptScrollView?.isHidden = true
            }
            return
        }

        layoutMode = newLayout
        currentBubbleSize = targetSize
        window.setContentSize(windowSize(for: targetSize))
        window.contentView?.layoutSubtreeIfNeeded()
        glassHostView?.layoutSubtreeIfNeeded()
        updateBorderGradientFrame(for: glassHostView?.bounds.size ?? targetSize)
        positionWindow()
        let cornerRadius = newLayout == .transcript ? Self.transcriptCornerRadius : Self.compactCornerRadius
        containerView?.layer?.cornerRadius = cornerRadius
        glassHostView?.layer?.cornerRadius = cornerRadius
        if newLayout == .transcript {
            statusTextField?.isHidden = true
            transcriptScrollView?.isHidden = false
        } else {
            statusTextField?.isHidden = false
            transcriptScrollView?.isHidden = true
        }
    }

    private func resetTranscriptBubbleGrowth() {
        transcriptBubbleHeight = TranscriptOverlayLayout.minimumTranscriptHeight
    }

    private func applyContinuousBubbleLayout() {
        let shouldPreserveTranscriptBubble =
            layoutMode == .transcript ||
            currentBubbleSize.width > Self.compactSize.width ||
            currentBubbleSize.height > Self.compactSize.height

        if shouldPreserveTranscriptBubble {
            applyLayout(.transcript, bubbleSize: currentBubbleSize)
        } else {
            applyLayout(.compact)
        }
    }

    private func updateBorderGradientFrame(for size: NSSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = NSRect(origin: .zero, size: size)
        auraPrimaryLayer?.frame = CGRect(x: -36, y: -18, width: rect.width + 72, height: rect.height + 54)
        auraSecondaryLayer?.frame = CGRect(x: rect.width * 0.08, y: -32, width: rect.width * 0.82, height: rect.height + 64)
        backgroundImageLayer?.frame = rect
        revealedBackgroundImageLayer?.frame = rect
        scrimLayer?.frame = rect
        glassTintLayer?.frame = rect
        sheenLayer?.frame = rect
        CATransaction.commit()
    }

    private func windowSize(for bubbleSize: NSSize) -> NSSize {
        NSSize(
            width: bubbleSize.width + (Self.windowPadding * 2),
            height: bubbleSize.height + (Self.windowPadding * 2)
        )
    }

    private func startDotPulse() {
        guard activePulseMode != .listening else { return }
        stopDotPulse()
        activePulseMode = .listening
        addBreathingAnimation(to: auraPrimaryLayer, key: "primaryBreath", scale: 1.08, opacity: 1.0)
        addBreathingAnimation(to: auraSecondaryLayer, key: "secondaryBreath", scale: 1.12, opacity: 0.86, duration: 3.8)
        addDriftAnimation(to: auraSecondaryLayer)
        startBorderAnimation()
    }

    private func startTranscribingPulse() {
        guard activePulseMode != .transcribing else { return }
        stopDotPulse()
        activePulseMode = .transcribing
        addBreathingAnimation(to: auraPrimaryLayer, key: "primaryBreath", scale: 1.08, opacity: 1.0)
        addBreathingAnimation(to: auraSecondaryLayer, key: "secondaryBreath", scale: 1.12, opacity: 0.86, duration: 3.8)
        addDriftAnimation(to: auraSecondaryLayer)
        startBorderAnimation()
        addBubblePulseAnimation(to: containerView?.layer, key: "transcribingBubblePulse")
        addOpacityPulseAnimation(to: glassHostView?.layer, key: "transcribingGlassPulse")
        addFieldRevealAnimation(to: revealedBackgroundImageLayer, key: "transcribingFieldReveal")
    }

    private func stopDotPulse() {
        activePulseMode = .none
        auraPrimaryLayer?.removeAllAnimations()
        auraSecondaryLayer?.removeAllAnimations()
        containerView?.layer?.removeAnimation(forKey: "transcribingBubblePulse")
        glassHostView?.layer?.removeAnimation(forKey: "transcribingGlassPulse")
        revealedBackgroundImageLayer?.removeAnimation(forKey: "transcribingFieldReveal")
        auraPrimaryLayer?.transform = CATransform3DIdentity
        auraSecondaryLayer?.transform = CATransform3DIdentity
        containerView?.layer?.transform = CATransform3DIdentity
        glassHostView?.layer?.opacity = 1.0
        revealedBackgroundImageLayer?.transform = CATransform3DIdentity
        auraPrimaryLayer?.opacity = 0.92
        auraSecondaryLayer?.opacity = 0.88
        containerView?.layer?.shadowRadius = 28
        containerView?.layer?.shadowOpacity = 0.85
        stopBorderAnimation()
    }

    private func startBorderAnimation() {
        // No-op: keeping the hook avoids broader overlay plumbing changes.
    }

    private func stopBorderAnimation() {
        // No-op.
    }

    private func updateBorderColors(for color: NSColor) {
        animateAura(color: color)
    }

    private func resetBorderToAccent() {
        animateAura(color: Self.accentBlue)
    }

    private func playSuccessBounce() {
        guard !reduceMotion else { return }

        // Quick scale up then settle back — a satisfying "pop"
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        containerView?.layer?.transform = CATransform3DMakeScale(1.03, 1.03, 1)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.3)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
                self?.containerView?.layer?.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
        CATransaction.commit()
    }

    private func applyAuraPalette(primary: NSColor, secondary: NSColor) {
        auraPrimaryLayer?.colors = [
            primary.withAlphaComponent(0.22).cgColor,
            secondary.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor
        ]
        auraSecondaryLayer?.colors = [
            secondary.withAlphaComponent(0.14).cgColor,
            primary.withAlphaComponent(0.04).cgColor,
            NSColor.clear.cgColor
        ]
        sheenLayer?.colors = [
            NSColor.white.withAlphaComponent(0.50).cgColor,
            NSColor.white.withAlphaComponent(0.12).cgColor,
            NSColor.clear.cgColor
        ]
        glassTintLayer?.colors = [
            primary.withAlphaComponent(0.04).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            secondary.withAlphaComponent(0.06).cgColor
        ]
        // Subtle tinted border.
        glassHostView?.layer?.borderColor = primary.blended(
            withFraction: 0.5, of: .white
        )?.withAlphaComponent(0.30).cgColor
        containerView?.layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
    }

    private var textShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.60)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 3
        return shadow
    }

    private func addBreathingAnimation(
        to layer: CALayer?,
        key: String,
        scale: CGFloat,
        opacity: Float,
        duration: CFTimeInterval = 3.1
    ) {
        guard !reduceMotion, let layer else { return }
        let animation = CAAnimationGroup()

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 0.96
        scaleAnimation.toValue = scale
        scaleAnimation.autoreverses = true

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = opacity * 0.72
        opacityAnimation.toValue = opacity
        opacityAnimation.autoreverses = true

        animation.animations = [scaleAnimation, opacityAnimation]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    private func addDriftAnimation(to layer: CALayer?) {
        guard !reduceMotion, let layer else { return }
        let drift = CABasicAnimation(keyPath: "transform.translation.x")
        drift.fromValue = -8
        drift.toValue = 8
        drift.duration = 5.4
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        drift.isRemovedOnCompletion = false
        layer.add(drift, forKey: "drift")
    }

    private func addBubblePulseAnimation(to layer: CALayer?, key: String) {
        guard !reduceMotion, let layer else { return }
        let animation = CAAnimationGroup()

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 0.985
        scaleAnimation.toValue = 1.018
        scaleAnimation.autoreverses = true

        let shadowRadiusAnimation = CABasicAnimation(keyPath: "shadowRadius")
        shadowRadiusAnimation.fromValue = 22
        shadowRadiusAnimation.toValue = 31
        shadowRadiusAnimation.autoreverses = true

        let shadowOpacityAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        shadowOpacityAnimation.fromValue = 0.68
        shadowOpacityAnimation.toValue = 0.94
        shadowOpacityAnimation.autoreverses = true

        animation.animations = [scaleAnimation, shadowRadiusAnimation, shadowOpacityAnimation]
        animation.duration = 1.18
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    private func addOpacityPulseAnimation(to layer: CALayer?, key: String) {
        guard !reduceMotion, let layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.84
        animation.toValue = 1.0
        animation.autoreverses = true
        animation.duration = 1.18
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    private func addFieldRevealAnimation(to layer: CALayer?, key: String) {
        guard !reduceMotion, let layer else { return }

        let animation = CAAnimationGroup()

        let driftAnimation = CABasicAnimation(keyPath: "transform.translation.x")
        driftAnimation.fromValue = -12
        driftAnimation.toValue = 12
        driftAnimation.autoreverses = true

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 1.02
        scaleAnimation.toValue = 1.08
        scaleAnimation.autoreverses = true

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.52
        opacityAnimation.toValue = 0.70
        opacityAnimation.autoreverses = true

        animation.animations = [driftAnimation, scaleAnimation, opacityAnimation]
        animation.duration = 8.2
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateListeningText()
            }
        }
        RunLoop.current.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        listeningStartDate = nil
    }

    private func updateListeningText() {
        guard let start = listeningStartDate else {
            statusTextField?.stringValue = "Listening 00:00"
            return
        }

        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let mode = listeningHandsFree ? "Hands-Free" : "Hold-to-Talk"
        statusTextField?.stringValue = "\(mode) \(String(format: "%02d:%02d", minutes, seconds))"
    }

    private func positionWindow() {
        guard let window else { return }

        // If the user dragged the overlay, keep it where they put it.
        if let draggedOrigin = userDraggedPosition {
            isPositioningProgrammatically = true
            window.setFrameOrigin(draggedOrigin)
            isPositioningProgrammatically = false
            return
        }

        if let pinnedOrigin = sessionPinnedOrigin {
            isPositioningProgrammatically = true
            window.setFrameOrigin(pinnedOrigin)
            isPositioningProgrammatically = false
            return
        }

        isPositioningProgrammatically = true
        defer { isPositioningProgrammatically = false }

        if let anchoredOrigin = anchoredWindowOrigin(for: window) {
            window.setFrameOrigin(anchoredOrigin)
            sessionPinnedOrigin = anchoredOrigin
            return
        }

        centerWindowNearTop()
        sessionPinnedOrigin = window.frame.origin
    }

    private func anchoredWindowOrigin(for window: NSWindow) -> NSPoint? {
        if let anchorSnapshot {
            return anchoredWindowOrigin(for: window, frame: anchorSnapshot.frame)
        }

        guard AXIsProcessTrusted(),
              let frame = currentFocusedFrame() else {
            return nil
        }

        return anchoredWindowOrigin(for: window, frame: frame)
    }

    private func anchoredWindowOrigin(for window: NSWindow, frame: CGRect) -> NSPoint? {
        let anchorPoint = NSPoint(x: frame.midX, y: frame.maxY)
        guard let screen = screen(containing: anchorPoint) else {
            return nil
        }

        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 12
        var x = anchorPoint.x - (window.frame.width / 2)
        var y = frame.maxY + margin

        x = min(max(x, visibleFrame.minX + margin), visibleFrame.maxX - window.frame.width - margin)
        y = min(y, visibleFrame.maxY - window.frame.height - margin)

        if y < visibleFrame.minY + margin {
            return nil
        }

        return NSPoint(x: x, y: y)
    }

    private func currentFocusedFrame() -> NSRect? {
        guard let element = focusedElement() else {
            return focusedWindowFrame()
        }

        if let markerBounds = selectedTextMarkerBounds(for: element) {
            return markerBounds
        }

        if let caretBounds = selectedTextBounds(for: element) {
            return caretBounds
        }

        if let elementFrame = elementFrame(for: element) {
            return elementFrame
        }

        return focusedWindowFrame()
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef,
        CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
    }

    private func selectedTextMarkerBounds(for element: AXUIElement) -> NSRect? {
        var selectedMarkerRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            Self.axSelectedTextMarkerRangeAttribute as CFString,
            &selectedMarkerRangeRef
        ) == .success,
        let selectedMarkerRangeRef else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            Self.axBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            selectedMarkerRangeRef,
            &boundsRef
        ) == .success,
        let boundsRef,
        CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsValue = unsafeDowncast(boundsRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(boundsValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect),
              !rect.isNull,
              !rect.isInfinite,
              rect.width >= 0,
              rect.height >= 0 else {
            return nil
        }

        return rect
    }

    private func selectedTextBounds(for element: AXUIElement) -> NSRect? {
        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
        let selectedRangeRef,
        CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let selectedRangeValue = unsafeDowncast(selectedRangeRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeValue,
            &boundsRef
        ) == .success,
        let boundsRef,
        CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsValue = unsafeDowncast(boundsRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(boundsValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect),
              !rect.isNull,
              !rect.isInfinite,
              rect.width >= 0,
              rect.height >= 0 else {
            return nil
        }

        return rect
    }

    private func elementFrame(for element: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize,
              AXValueGetValue(positionAXValue, .cgPoint, &point),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return NSRect(origin: point, size: size)
    }

    private func focusedWindowFrame() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appRef
        ) == .success,
        let appRef,
        CFGetTypeID(appRef) == AXUIElementGetTypeID() else {
            return nil
        }

        let appElement = unsafeDowncast(appRef as AnyObject, to: AXUIElement.self)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success,
        let windowRef,
        CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return nil
        }

        let windowElement = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        return elementFrame(for: windowElement)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func centerWindowNearTop() {
        guard let window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2
        let y = screenFrame.origin.y + screenFrame.height - window.frame.height - 40
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func loadBackgroundImage() -> NSImage? {
        // Try the app's asset catalog first.
        if let img = NSImage(named: "RecordBackground") {
            return img
        }
        // Fallback: search the main bundle for the loose file.
        if let url = Bundle.main.url(forResource: "record-background", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        #if DEBUG
        // Debug fallback for standalone preview harness.
        let devPath = "/tmp/record-background.png"
        if FileManager.default.fileExists(atPath: devPath) {
            return NSImage(contentsOfFile: devPath)
        }
        #endif
        return nil
    }

    private static func loadBackgroundCGImage() -> CGImage? {
        guard let image = loadBackgroundImage() else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func loadBlurredBackgroundImage() -> CGImage? {
        guard let cgImage = loadBackgroundCGImage() else { return nil }

        let sourceImage = CIImage(cgImage: cgImage)
        let blurredImage = sourceImage
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: 12]
            )
            .cropped(to: sourceImage.extent)

        let context = CIContext(options: [.cacheIntermediates: true])
        return context.createCGImage(blurredImage, from: sourceImage.extent) ?? cgImage
    }

    private func endInteractiveRepositionMode(notify: Bool = true) {
        repositionModeTask?.cancel()
        repositionModeTask = nil
        repositionModeEnabled = false
        window?.ignoresMouseEvents = true
        window?.isMovableByWindowBackground = false
        if notify {
            notifyDragIfNeeded()
        }
    }

    private func notifyDragIfNeeded() {
        guard userDidDrag, let position = userDraggedPosition else { return }
        userDidDrag = false
        onUserDraggedToPosition?(position)
    }

    @objc
    private func accessibilityDisplayOptionsDidChange(_: Notification) {
        handleAccessibilityDisplayOptionsDidChange()
    }

    private func handleAccessibilityDisplayOptionsDidChange() {
        guard reduceMotion else { return }
        stopDotPulse()
    }
}
#endif
