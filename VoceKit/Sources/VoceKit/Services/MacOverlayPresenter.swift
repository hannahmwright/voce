#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
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

private final class OverlayPassThroughView: NSView {
    weak var interactiveView: NSView?
    var acceptsBubbleInteraction = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsBubbleInteraction,
              let interactiveView else {
            return nil
        }

        let convertedPoint = interactiveView.convert(point, from: self)
        guard interactiveView.bounds.contains(convertedPoint) else {
            return nil
        }

        return super.hitTest(point)
    }
}

@MainActor
private final class OverlayBubbleView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

@MainActor
private final class BubbleControlMenuButton: NSButton {
    private let normalBackgroundColor: NSColor
    private let hoverBackgroundColor: NSColor
    private let pressedBackgroundColor: NSColor
    private let borderColor: NSColor
    private let titleColor: NSColor
    private let iconColor: NSColor
    private let buttonFont: NSFont
    private let buttonTitle: String
    private let onClick: @MainActor () -> Void
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(
        title: String,
        symbolName: String,
        font: NSFont,
        titleColor: NSColor,
        iconColor: NSColor,
        backgroundColor: NSColor,
        hoverBackgroundColor: NSColor,
        pressedBackgroundColor: NSColor,
        borderColor: NSColor,
        onClick: @escaping @MainActor () -> Void
    ) {
        self.normalBackgroundColor = backgroundColor
        self.hoverBackgroundColor = hoverBackgroundColor
        self.pressedBackgroundColor = pressedBackgroundColor
        self.borderColor = borderColor
        self.titleColor = titleColor
        self.iconColor = iconColor
        self.buttonFont = font
        self.buttonTitle = title
        self.onClick = onClick
        super.init(frame: .zero)

        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        self.title = ""
        self.image = nil
        target = self
        action = #selector(handleClick)
        sendAction(on: [.leftMouseDown])

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5

        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.distribution = .fill
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleField)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateTitle()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    override var isHighlighted: Bool {
        didSet {
            updateAppearance()
        }
    }

    @objc
    private func handleClick() {
        onClick()
    }

    private func updateTitle() {
        titleField.stringValue = buttonTitle
        titleField.font = buttonFont
        titleField.textColor = titleColor
    }

    private func updateAppearance() {
        let background = isHighlighted
            ? pressedBackgroundColor
            : (isHovering ? hoverBackgroundColor : normalBackgroundColor)
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = borderColor.cgColor
        iconView.contentTintColor = iconColor
        updateTitle()
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
    private var hitTestCanvasView: OverlayPassThroughView?
    private var containerView: NSView?
    private var glassHostView: NSView?
    private var backgroundImageLayer: CALayer?
    private var revealedBackgroundImageLayer: CALayer?
    private var processingVideoLayer: AVPlayerLayer?
    private var scrimLayer: CAGradientLayer?
    private var auraPrimaryLayer: CAGradientLayer?
    private var auraSecondaryLayer: CAGradientLayer?
    private var glassTintLayer: CAGradientLayer?
    private var sheenLayer: CAGradientLayer?
    private var meterBarLayers: [CALayer] = []
    private var processingIndicatorLayer: CAShapeLayer?
    private var processingRunnerLayer: CALayer?
    private var latestAudioLevel: Double = 0.18
    private var statusTextField: NSTextField?
    private var transcriptBackdropView: NSView?
    private var transcriptScrollView: NSScrollView?
    private var transcriptTextView: NSTextView?
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var wasHidden = true
    private var anchorSnapshot: AnchorSnapshot?
    private var layoutMode: LayoutMode = .compact
    private var isBubbleHovered = false
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
    private var processingPlayer: AVPlayer?
    private var processingPlayerURL: URL?
    private var processingBoundaryObserver: Any?
    private var processingTimeObserver: Any?
    private var bubbleControlsEnabled = false
    private var controlMenuWindow: NSPanel?
    private var controlMenuLocalEventMonitor: Any?
    private var controlMenuGlobalEventMonitor: Any?

    /// When non-nil, overrides the overlay window's own effective appearance
    /// for choosing the processing video (light vs dark).  Set this to the
    /// app-level dark-mode preference so the overlay stays in sync even though
    /// it lives in a standalone NSPanel outside the SwiftUI view hierarchy.
    public var prefersDarkAppearance: Bool? {
        didSet {
            guard oldValue != prefersDarkAppearance else { return }
            refreshSurfaceAssets()
            applyAppearanceForCurrentState()
        }
    }
    public var bubbleAppearance: OverlayBubbleAppearance = .matchApp {
        didSet {
            guard oldValue != bubbleAppearance else { return }
            refreshSurfaceAssets()
            applyAppearanceForCurrentState()
        }
    }
    public var controlWorkflows: [AIWorkflow] = []
    public var selectedControlStyle: StructureMode = .paragraph
    public var onStopRequested: (() -> Void)?
    public var onAIWorkflowRequested: ((UUID) -> Void)?
    public var onStyleRequested: ((StructureMode) -> Void)?

    /// Called when the user finishes dragging the overlay to a new position.
    /// Provides the window origin so the caller can persist it per-app.
    public var onUserDraggedToPosition: ((NSPoint) -> Void)?

    // Monet-inspired palette matching the app's DesignSystem.
    private static let accentBlue = NSColor(red: 0.32, green: 0.60, blue: 0.82, alpha: 1.0)    // cerulean
    private static let accentCyan = NSColor(red: 0.62, green: 0.78, blue: 0.90, alpha: 1.0)    // sky blue
    private static let accentLavender = NSColor(red: 0.72, green: 0.70, blue: 0.84, alpha: 1.0) // lavender haze
    private static let accentWheat = NSColor(red: 0.82, green: 0.74, blue: 0.52, alpha: 1.0)   // golden wheat
    private static let warmAccentFill = NSColor(red: 0.84, green: 0.89, blue: 0.76, alpha: 1.0)
    private static let warmAccentText = NSColor(red: 0.27, green: 0.34, blue: 0.19, alpha: 1.0)
    private static let techBackground = NSColor(red: 0.055, green: 0.075, blue: 0.095, alpha: 0.92)
    private static let techAccent = NSColor(red: 0.38, green: 0.95, blue: 0.82, alpha: 1.0)
    private static let compactCornerRadius: CGFloat = 26
    private static let transcriptCornerRadius: CGFloat = 30
    private static let initialTranscriptShellHeight: CGFloat = 78

    private static func menuTextPrimaryColor(dark: Bool) -> NSColor {
        dark
            ? NSColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1.0)
            : NSColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
    }

    private static func menuTextSecondaryColor(dark: Bool) -> NSColor {
        menuTextPrimaryColor(dark: dark).withAlphaComponent(dark ? 0.66 : 0.58)
    }

    private static func menuSurfaceColor(dark: Bool) -> NSColor {
        dark
            ? NSColor(red: 0.18, green: 0.19, blue: 0.21, alpha: 0.90)
            : NSColor.white.withAlphaComponent(0.84)
    }

    private static func menuSurfaceSecondaryColor(dark: Bool) -> NSColor {
        dark
            ? NSColor(red: 0.21, green: 0.22, blue: 0.24, alpha: 0.88)
            : NSColor.white.withAlphaComponent(0.80)
    }

    private static func menuBorderColor(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.06)
    }

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
            processingPlayer?.pause()
            removeProcessingObservers()
            processingPlayer = nil
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
        sessionPinnedOrigin = window.frame.origin
        hitTestCanvasView?.acceptsBubbleInteraction = true
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
            setBubbleControlsEnabled(true)
            listeningHandsFree = handsFree
            listeningStartDate = Date()
            lastLiveTranscriptText = ""
            hasShownLiveTranscriptInSession = false
            resetTranscriptBubbleGrowth()
            showCompactListeningBadge()

        case .liveTranscript(let text, _):
            setBubbleControlsEnabled(true)
            lastLiveTranscriptText = text
            hasShownLiveTranscriptInSession = true
            let shouldExpand = isBubbleHovered && isMouseCurrentlyInsideBubble()
            isBubbleHovered = shouldExpand
            if shouldExpand {
                updateTranscript(text)
            } else {
                showCompactListeningBadge()
            }

        case .transcribing:
            setBubbleControlsEnabled(false)
            stopTimer()
            showCompactProcessingBadge()

        case .inserted:
            setBubbleControlsEnabled(false)
            applyDefaultSurfaceAppearance()
            applyLayout(.compact)
            stopTimer()
            stopDotPulse()
            hideContent()
            resetBorderToAccent()
            playSuccessBounce()

        case .copiedOnly:
            setBubbleControlsEnabled(false)
            applyDefaultSurfaceAppearance()
            applyLayout(.compact)
            stopTimer()
            stopDotPulse()
            hideContent()
            resetBorderToAccent()

        case .failure:
            setBubbleControlsEnabled(false)
            applyDefaultSurfaceAppearance()
            applyLayout(.compact)
            stopTimer()
            stopDotPulse()
            hideContent()
            animateAura(color: .systemRed)
            updateBorderColors(for: .systemRed)
        }

        positionWindow()

        if isFirstShow && !reduceMotion {
            // Entrance animation: fade in + gentle scale without shifting position.
            window?.alphaValue = 0
            containerView?.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            window?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // spring-like
                self.window?.animator().alphaValue = 1
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
        setBubbleControlsEnabled(false)

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
        setBubbleControlsEnabled(false)

        if !reduceMotion {
            // Exit: fade out + subtle scale down without shifting position.

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
            containerView?.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
            CATransaction.commit()

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.window?.animator().alphaValue = 0
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
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let canvas = OverlayPassThroughView(frame: contentRect)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.clear.cgColor
        self.hitTestCanvasView = canvas

        let bubbleRect = CGRect(
            x: Self.windowPadding,
            y: Self.windowPadding,
            width: Self.compactSize.width,
            height: Self.compactSize.height
        )

        let container = OverlayBubbleView(frame: bubbleRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.compactCornerRadius
        container.layer?.masksToBounds = false
        container.onHoverChanged = { [weak self] hovering in
            self?.handleBubbleHoverChanged(hovering)
        }
        self.containerView = container
        canvas.interactiveView = container

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
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleBubbleControlClick(_:)))
        clickRecognizer.buttonMask = 0x1
        glassHost.addGestureRecognizer(clickRecognizer)

        // Background painting — blurred, bright, airy like the app window.
        let imageLayer = CALayer()
        if let cgImage = Self.loadBlurredBackgroundImage(isDark: prefersDarkProcessingVideo) {
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
        if let cgImage = Self.loadBackgroundCGImage(isDark: prefersDarkProcessingVideo) {
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

        let processingVideoLayer = AVPlayerLayer()
        processingVideoLayer.videoGravity = .resizeAspectFill
        processingVideoLayer.opacity = 0.0
        processingVideoLayer.frame = glassHost.bounds
        processingVideoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glassHost.layer?.addSublayer(processingVideoLayer)
        self.processingVideoLayer = processingVideoLayer

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

        let processingIndicatorLayer = CAShapeLayer()
        processingIndicatorLayer.fillColor = Self.accentBlue.withAlphaComponent(0.72).cgColor
        processingIndicatorLayer.opacity = 0.0
        glassHost.layer?.addSublayer(processingIndicatorLayer)
        self.processingIndicatorLayer = processingIndicatorLayer

        let processingRunnerLayer = CALayer()
        processingRunnerLayer.backgroundColor = Self.techAccent.withAlphaComponent(0.86).cgColor
        processingRunnerLayer.cornerRadius = 4
        processingRunnerLayer.opacity = 0.0
        processingRunnerLayer.shadowColor = Self.techAccent.withAlphaComponent(0.45).cgColor
        processingRunnerLayer.shadowOpacity = 1
        processingRunnerLayer.shadowOffset = .zero
        processingRunnerLayer.shadowRadius = 8
        glassHost.layer?.addSublayer(processingRunnerLayer)
        self.processingRunnerLayer = processingRunnerLayer

        meterBarLayers = (0..<12).map { _ in
            let layer = CALayer()
            layer.backgroundColor = Self.techAccent.withAlphaComponent(0.74).cgColor
            layer.cornerRadius = 2
            layer.opacity = 0.0
            glassHost.layer?.addSublayer(layer)
            return layer
        }

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
        updateProcessingIndicatorFrame()
        updateMeterBarFrames(level: 0.18)

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

        // Transcript preview sits above the listening meter so hover keeps the speech animation visible.
        let transcriptBackdropView = NSView(frame: .zero)
        transcriptBackdropView.wantsLayer = true
        transcriptBackdropView.layer?.cornerRadius = 12
        transcriptBackdropView.layer?.masksToBounds = true
        transcriptBackdropView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
        transcriptBackdropView.layer?.borderWidth = 0.5
        transcriptBackdropView.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        transcriptBackdropView.translatesAutoresizingMaskIntoConstraints = false
        transcriptBackdropView.isHidden = true
        glassHost.addSubview(transcriptBackdropView)
        self.transcriptBackdropView = transcriptBackdropView

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
        transcriptBackdropView.addSubview(transcriptScrollView)
        self.transcriptTextView = transcriptTextView
        self.transcriptScrollView = transcriptScrollView

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: glassHost.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: glassHost.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: glassHost.centerYAnchor),

            transcriptBackdropView.leadingAnchor.constraint(equalTo: glassHost.leadingAnchor, constant: 12),
            transcriptBackdropView.trailingAnchor.constraint(equalTo: glassHost.trailingAnchor, constant: -12),
            transcriptBackdropView.topAnchor.constraint(equalTo: glassHost.topAnchor, constant: 10),
            transcriptBackdropView.bottomAnchor.constraint(equalTo: glassHost.bottomAnchor, constant: -12),

            transcriptScrollView.leadingAnchor.constraint(equalTo: transcriptBackdropView.leadingAnchor, constant: 12),
            transcriptScrollView.trailingAnchor.constraint(equalTo: transcriptBackdropView.trailingAnchor, constant: -12),
            transcriptScrollView.topAnchor.constraint(equalTo: transcriptBackdropView.topAnchor, constant: 6),
            transcriptScrollView.bottomAnchor.constraint(equalTo: transcriptBackdropView.bottomAnchor, constant: -6)
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
        transcriptBackdropView?.isHidden = true
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

    public func updateAudioLevel(_ level: Double) {
        guard activePulseMode == .listening,
              !meterBarLayers.isEmpty else { return }
        latestAudioLevel = min(max(level, 0), 1)
        updateMeterBarFrames(level: level)
    }

    private func updateMeterBarFrames(level: Double) {
        guard let glassHostView, !meterBarLayers.isEmpty else { return }
        updateMeterBarFrames(level: level, in: glassHostView.bounds)
    }

    private func updateMeterBarFrames(level: Double, in bounds: CGRect) {
        guard !meterBarLayers.isEmpty else { return }
        let barCount = meterBarLayers.count
        let barWidth: CGFloat = bubbleAppearance == .techMeter ? 3 : 4
        let spacing: CGFloat = 3
        let totalWidth = (CGFloat(barCount) * barWidth) + (CGFloat(barCount - 1) * spacing)
        let startX = max(12, bounds.midX - (totalWidth / 2))
        let baselineY: CGFloat = 12
        let baseLevel = pow(min(max(level, 0), 1), 0.52)
        let minHeight: CGFloat = 5
        let maxHeight: CGFloat = 25

        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(0.07)
        for (index, layer) in meterBarLayers.enumerated() {
            let phase = Double(index) / Double(max(barCount - 1, 1))
            let variation = 0.48 + (0.52 * abs(sin((phase * .pi * 2) + (Date().timeIntervalSince1970 * 4.4))))
            let height = minHeight + (baseLevel * variation * maxHeight)
            layer.backgroundColor = meterBarColor.withAlphaComponent(0.70).cgColor
            layer.frame = CGRect(
                x: startX + (CGFloat(index) * (barWidth + spacing)),
                y: baselineY,
                width: barWidth,
                height: max(minHeight, height)
            )
            layer.opacity = Float(0.30 + (baseLevel * 0.54))
        }
        CATransaction.commit()
    }

    private func updateProcessingIndicatorFrame() {
        guard let glassHostView else { return }
        updateProcessingIndicatorFrame(in: glassHostView.bounds.size)
    }

    private func updateProcessingIndicatorFrame(in size: NSSize) {
        guard let processingIndicatorLayer else { return }
        let rect = CGRect(x: size.width - 22, y: 14, width: 7, height: 7)
        let path = CGPath(ellipseIn: rect, transform: nil)
        processingIndicatorLayer.path = path
    }

    private func updateProcessingRunnerFrame() {
        guard let glassHostView else { return }
        updateProcessingRunnerFrame(in: glassHostView.bounds.size)
    }

    private func updateProcessingRunnerFrame(in hostSize: NSSize) {
        guard let processingRunnerLayer else { return }
        let runnerSize = CGSize(width: 18, height: 7)
        processingRunnerLayer.bounds = CGRect(origin: .zero, size: runnerSize)
        processingRunnerLayer.cornerRadius = runnerSize.height / 2
        processingRunnerLayer.position = CGPoint(x: hostSize.width / 2, y: hostSize.height / 2)
    }

    private func setMeterVisible(_ visible: Bool) {
        for layer in meterBarLayers {
            layer.opacity = visible ? max(layer.opacity, 0.24) : 0.0
        }
    }

    private func startMeterBars() {
        updateMeterBarFrames(level: max(latestAudioLevel, 0.18))
        setMeterVisible(true)
    }

    private func addProcessingIndicatorAnimation() {
        guard bubbleAppearance == .techMeter else { return }
        startTechProcessingRunnerAnimation()
    }

    private func startTechProcessingRunnerAnimation() {
        guard let glassHostView, let layer = processingRunnerLayer else { return }
        updateProcessingRunnerFrame()
        layer.removeAllAnimations()
        layer.backgroundColor = Self.techAccent.withAlphaComponent(0.86).cgColor
        layer.opacity = 0.92

        guard !reduceMotion else { return }

        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = glassHostView.bounds.minX + 18
        travel.toValue = glassHostView.bounds.maxX - 18
        travel.duration = 1.05
        travel.autoreverses = true
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        travel.isRemovedOnCompletion = false

        let squash = CABasicAnimation(keyPath: "transform.scale.x")
        squash.fromValue = 0.72
        squash.toValue = 1.28
        squash.duration = 0.34
        squash.autoreverses = true
        squash.repeatCount = .infinity
        squash.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        squash.isRemovedOnCompletion = false

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.56
        pulse.toValue = 0.96
        pulse.duration = 0.48
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false

        layer.add(travel, forKey: "techRunnerTravel")
        layer.add(squash, forKey: "techRunnerSquash")
        layer.add(pulse, forKey: "techRunnerPulse")
    }

    private func stopTechProcessingRunnerAnimation() {
        processingRunnerLayer?.removeAllAnimations()
        processingRunnerLayer?.opacity = 0.0
    }

    private func updateTranscript(_ text: String, preserveBubbleShell: Bool = false) {
        statusTextField?.isHidden = true
        transcriptBackdropView?.isHidden = false
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
        transcriptBackdropView?.isHidden = true
        transcriptScrollView?.isHidden = true
    }

    private func applyDefaultSurfaceAppearance() {
        stopProcessingVideo()
        processingVideoLayer?.opacity = 0.0
        processingIndicatorLayer?.opacity = 0.0
        stopTechProcessingRunnerAnimation()
        if bubbleAppearance == .techMeter {
            applyTechSurfaceAppearance(isProcessing: false)
            return
        }

        backgroundImageLayer?.opacity = 0.70
        revealedBackgroundImageLayer?.opacity = 0.0
        scrimLayer?.colors = [
            bubbleSurfaceColor(lightAlpha: 0.82, darkAlpha: 0.78).cgColor,
            bubbleSurfaceColor(lightAlpha: 0.62, darkAlpha: 0.56).cgColor,
            bubbleSurfaceColor(lightAlpha: 0.35, darkAlpha: 0.36).cgColor
        ]
        glassTintLayer?.colors = [
            Self.accentCyan.withAlphaComponent(0.06).cgColor,
            neutralSurfaceColor(lightAlpha: 0.02, darkAlpha: 0.04).cgColor,
            Self.accentWheat.withAlphaComponent(0.10).cgColor
        ]
        sheenLayer?.opacity = 1.0
        glassHostView?.layer?.backgroundColor = NSColor.clear.cgColor
        glassHostView?.layer?.borderColor = bubbleBorderColor.cgColor
        statusTextField?.textColor = bubbleTextColor
        statusTextField?.shadow = resolvedTextShadow
        setMeterVisible(activePulseMode == .listening)
    }

    private func applyTranscribingSurfaceAppearance() {
        if bubbleAppearance == .techMeter {
            stopProcessingVideo()
            applyTechSurfaceAppearance(isProcessing: true)
            return
        }

        playProcessingVideoIfNeeded()
        backgroundImageLayer?.opacity = 0.0
        revealedBackgroundImageLayer?.opacity = 0.0
        processingVideoLayer?.opacity = 1.0
        processingIndicatorLayer?.opacity = 0.0
        stopTechProcessingRunnerAnimation()
        scrimLayer?.colors = [
            bubbleSurfaceColor(lightAlpha: 0.28, darkAlpha: 0.32).cgColor,
            bubbleSurfaceColor(lightAlpha: 0.16, darkAlpha: 0.22).cgColor,
            bubbleSurfaceColor(lightAlpha: 0.08, darkAlpha: 0.14).cgColor
        ]
        glassTintLayer?.colors = [
            Self.accentCyan.withAlphaComponent(0.03).cgColor,
            neutralSurfaceColor(lightAlpha: 0.01, darkAlpha: 0.03).cgColor,
            Self.accentWheat.withAlphaComponent(0.04).cgColor
        ]
        sheenLayer?.opacity = 0.42
        glassHostView?.layer?.backgroundColor = NSColor.clear.cgColor
        glassHostView?.layer?.borderColor = bubbleBorderColor.cgColor
        statusTextField?.textColor = bubbleTextColor
        statusTextField?.shadow = resolvedTextShadow
        setMeterVisible(false)
    }

    private func applyTechSurfaceAppearance(isProcessing: Bool) {
        backgroundImageLayer?.opacity = 0.0
        revealedBackgroundImageLayer?.opacity = 0.0
        processingVideoLayer?.opacity = 0.0
        scrimLayer?.colors = [
            Self.techBackground.withAlphaComponent(isProcessing ? 0.86 : 0.92).cgColor,
            NSColor(red: 0.08, green: 0.10, blue: 0.13, alpha: isProcessing ? 0.80 : 0.88).cgColor,
            NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 0.92).cgColor
        ]
        glassTintLayer?.colors = [
            Self.techAccent.withAlphaComponent(isProcessing ? 0.08 : 0.12).cgColor,
            Self.accentBlue.withAlphaComponent(0.05).cgColor,
            NSColor.black.withAlphaComponent(0.04).cgColor
        ]
        sheenLayer?.opacity = 0.20
        processingIndicatorLayer?.fillColor = Self.techAccent.withAlphaComponent(0.72).cgColor
        processingIndicatorLayer?.opacity = 0.0
        if isProcessing {
            startTechProcessingRunnerAnimation()
        } else {
            stopTechProcessingRunnerAnimation()
        }
        glassHostView?.layer?.backgroundColor = Self.techBackground.cgColor
        glassHostView?.layer?.borderColor = Self.techAccent.withAlphaComponent(isProcessing ? 0.38 : 0.26).cgColor
        containerView?.layer?.shadowColor = Self.techAccent.withAlphaComponent(0.16).cgColor
        statusTextField?.textColor = NSColor(red: 0.80, green: 1.0, blue: 0.94, alpha: 0.92)
        statusTextField?.shadow = nil
        setMeterVisible(!isProcessing)
    }

    private func applyLayout(_ newLayout: LayoutMode, bubbleSize requestedSize: NSSize? = nil) {
        guard let window else { return }
        let targetSize = requestedSize ?? (newLayout == .transcript ? Self.transcriptSize : Self.compactSize)
        guard layoutMode != newLayout || currentBubbleSize != targetSize else {
            if newLayout == .transcript {
                statusTextField?.isHidden = true
                transcriptBackdropView?.isHidden = false
                transcriptScrollView?.isHidden = false
            } else {
                statusTextField?.isHidden = false
                transcriptBackdropView?.isHidden = true
                transcriptScrollView?.isHidden = true
            }
            return
        }

        layoutMode = newLayout
        currentBubbleSize = targetSize
        window.setContentSize(windowSize(for: targetSize))
        updateOverlayFrames(for: targetSize, audioLevel: 0.18)
        positionWindow()
        let cornerRadius = newLayout == .transcript ? Self.transcriptCornerRadius : Self.compactCornerRadius
        containerView?.layer?.cornerRadius = cornerRadius
        glassHostView?.layer?.cornerRadius = cornerRadius
        if newLayout == .transcript {
            statusTextField?.isHidden = true
            transcriptBackdropView?.isHidden = false
            transcriptScrollView?.isHidden = false
        } else {
            statusTextField?.isHidden = false
            transcriptBackdropView?.isHidden = true
            transcriptScrollView?.isHidden = true
        }
    }

    private func resetTranscriptBubbleGrowth() {
        transcriptBubbleHeight = TranscriptOverlayLayout.minimumTranscriptHeight
    }

    private func showCompactListeningBadge() {
        applyLayout(.compact)
        transcriptBackdropView?.isHidden = true
        transcriptScrollView?.isHidden = true
        statusTextField?.isHidden = true
        resetBorderToAccent()
        applyDefaultSurfaceAppearance()
        startDotPulse()
        startMeterBars()
        startTimer()
        updateListeningText()
    }

    private func showCompactProcessingBadge() {
        applyLayout(.compact)
        transcriptBackdropView?.isHidden = true
        transcriptScrollView?.isHidden = true
        statusTextField?.isHidden = true
        resetBorderToAccent()
        applyTranscribingSurfaceAppearance()
        startTranscribingPulse()
    }

    private func handleBubbleHoverChanged(_ hovering: Bool) {
        isBubbleHovered = hovering
        guard activePulseMode == .listening else { return }
        let transcript = lastLiveTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        if hovering {
            updateTranscript(transcript)
        } else {
            showCompactListeningBadge()
        }
    }

    private func isMouseCurrentlyInsideBubble() -> Bool {
        guard let window,
              let containerView,
              window.isVisible,
              !wasHidden
        else {
            return false
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let containerPoint = containerView.convert(windowPoint, from: nil)
        return containerView.bounds.contains(containerPoint)
    }

    private func setBubbleControlsEnabled(_ enabled: Bool) {
        bubbleControlsEnabled = enabled
        hitTestCanvasView?.acceptsBubbleInteraction = enabled || repositionModeEnabled
        if !enabled {
            hideBubbleControlMenu(animated: false)
        }
    }

    @objc
    private func handleBubbleControlClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended,
              bubbleControlsEnabled,
              !repositionModeEnabled else {
            return
        }

        if controlMenuWindow?.isVisible == true {
            hideBubbleControlMenu(animated: true)
        } else {
            showBubbleControlMenu()
        }
    }

    private func showBubbleControlMenu() {
        guard let window,
              let glassHostView else { return }

        hideBubbleControlMenu(animated: false)

        let enabledWorkflows = controlWorkflows.filter(\.isEnabled)
        let panelWidth: CGFloat = min(max(currentBubbleSize.width, 268), 324)
        let contentView = makeBubbleControlMenuView(width: panelWidth, workflows: enabledWorkflows)
        contentView.layoutSubtreeIfNeeded()
        let panelSize = NSSize(width: panelWidth, height: max(contentView.fittingSize.height, 104))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = contentView

        let bubbleInWindow = glassHostView.convert(glassHostView.bounds, to: nil)
        let bubbleScreenRect = window.convertToScreen(bubbleInWindow)
        let finalFrame = controlMenuFrame(
            size: panelSize,
            bubbleScreenRect: bubbleScreenRect,
            screen: window.screen
        )
        let startFrame = finalFrame.offsetBy(dx: 0, dy: -10)

        controlMenuWindow = panel
        installBubbleControlMenuEventMonitors()
        window.addChildWindow(panel, ordered: .above)

        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.01 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    private func handleStopDictationButton() {
        hideBubbleControlMenu(animated: true)
        onStopRequested?()
    }

    private func handleAIWorkflowButton(workflowID: UUID) {
        hideBubbleControlMenu(animated: true)
        onAIWorkflowRequested?(workflowID)
    }

    private func handleStyleButton(mode: StructureMode) {
        selectedControlStyle = mode
        hideBubbleControlMenu(animated: true)
        onStyleRequested?(mode)
    }

    private var isDarkAppearance: Bool {
        if let override = prefersDarkAppearance {
            return override
        }

        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func makeBubbleControlMenuView(width: CGFloat, workflows: [AIWorkflow]) -> NSView {
        let dark = isDarkAppearance
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.widthAnchor.constraint(equalToConstant: width).isActive = true

        let menuSize = NSSize(width: width, height: 320)
        let imageLayer = CALayer()
        if let cgImage = Self.loadBackgroundCGImage(isDark: dark) {
            imageLayer.contents = cgImage
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.minificationFilter = .trilinear
            imageLayer.magnificationFilter = .trilinear
            imageLayer.opacity = dark ? 0.50 : 0.72
        }
        imageLayer.frame = CGRect(origin: .zero, size: menuSize)
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(imageLayer)

        let backdropWash = CAGradientLayer()
        backdropWash.colors = dark
            ? [
                NSColor(calibratedWhite: 0.10, alpha: 0.36).cgColor,
                NSColor(calibratedWhite: 0.06, alpha: 0.18).cgColor,
                Self.accentWheat.withAlphaComponent(0.10).cgColor,
            ]
            : [
                NSColor.white.withAlphaComponent(0.12).cgColor,
                NSColor.white.withAlphaComponent(0.03).cgColor,
                Self.accentWheat.withAlphaComponent(0.10).cgColor,
            ]
        backdropWash.startPoint = CGPoint(x: 0, y: 1)
        backdropWash.endPoint = CGPoint(x: 1, y: 0)
        backdropWash.frame = CGRect(origin: .zero, size: menuSize)
        backdropWash.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(backdropWash)

        let chrome = NSView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 16
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 0
        chrome.layer?.borderColor = NSColor.clear.cgColor
        chrome.layer?.backgroundColor = Self.menuSurfaceColor(dark: dark).cgColor
        root.addSubview(chrome)

        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            chrome.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            chrome.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        let chromeTint = CAGradientLayer()
        chromeTint.colors = dark
            ? [
                Self.accentCyan.withAlphaComponent(0.08).cgColor,
                NSColor.white.withAlphaComponent(0.02).cgColor,
                Self.accentWheat.withAlphaComponent(0.08).cgColor,
            ]
            : [
                Self.accentCyan.withAlphaComponent(0.12).cgColor,
                NSColor.white.withAlphaComponent(0.10).cgColor,
                Self.accentWheat.withAlphaComponent(0.12).cgColor,
            ]
        chromeTint.startPoint = CGPoint(x: 0, y: 1)
        chromeTint.endPoint = CGPoint(x: 1, y: 0)
        chromeTint.frame = CGRect(origin: .zero, size: menuSize)
        chromeTint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        chrome.layer?.addSublayer(chromeTint)

        let chromeSheen = CAGradientLayer()
        chromeSheen.colors = [
            NSColor.white.withAlphaComponent(dark ? 0.16 : 0.42).cgColor,
            NSColor.white.withAlphaComponent(dark ? 0.05 : 0.10).cgColor,
            NSColor.clear.cgColor,
        ]
        chromeSheen.locations = [0, 0.22, 1]
        chromeSheen.startPoint = CGPoint(x: 0.15, y: 1.0)
        chromeSheen.endPoint = CGPoint(x: 0.85, y: 0.0)
        chromeSheen.frame = CGRect(origin: .zero, size: menuSize)
        chromeSheen.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        chrome.layer?.addSublayer(chromeSheen)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -16),
        ])

        if !workflows.isEmpty {
            let workflowStack = NSStackView()
            workflowStack.orientation = .vertical
            workflowStack.alignment = .leading
            workflowStack.distribution = .fill
            workflowStack.spacing = 6
            workflowStack.translatesAutoresizingMaskIntoConstraints = false

            for (index, workflow) in workflows.enumerated() {
                let button = makeBubbleControlButton(
                    title: workflow.name,
                    symbolName: "sparkles",
                    emphasized: false,
                    dark: dark
                ) { [weak self] in
                    self?.handleAIWorkflowButton(workflowID: workflow.id)
                }
                workflowStack.addArrangedSubview(button)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: workflowStack.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: workflowStack.trailingAnchor),
                ])

                if index < workflows.count - 1 {
                    let divider = makeBubbleControlDivider(dark: dark)
                    workflowStack.addArrangedSubview(divider)
                    NSLayoutConstraint.activate([
                        divider.heightAnchor.constraint(equalToConstant: 1),
                        divider.leadingAnchor.constraint(equalTo: workflowStack.leadingAnchor, constant: 14),
                        divider.trailingAnchor.constraint(equalTo: workflowStack.trailingAnchor, constant: -14),
                    ])
                }
            }

            stack.addArrangedSubview(workflowStack)
            NSLayoutConstraint.activate([
                workflowStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                workflowStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        let styleStack = NSStackView()
        styleStack.orientation = .vertical
        styleStack.alignment = .leading
        styleStack.distribution = .fill
        styleStack.spacing = 6
        styleStack.translatesAutoresizingMaskIntoConstraints = false

        let styleHeader = makeBubbleControlSectionLabel("Change style", dark: dark)
        styleStack.addArrangedSubview(styleHeader)
        NSLayoutConstraint.activate([
            styleHeader.leadingAnchor.constraint(equalTo: styleStack.leadingAnchor, constant: 8),
            styleHeader.trailingAnchor.constraint(equalTo: styleStack.trailingAnchor, constant: -8),
        ])

        let styleModes: [StructureMode] = [.natural, .paragraph, .bullets, .email, .command]
        for mode in styleModes {
            let selected = mode == selectedControlStyle
            let button = makeBubbleControlButton(
                title: Self.controlStyleTitle(for: mode),
                symbolName: selected ? "checkmark.circle.fill" : "circle",
                emphasized: selected,
                dark: dark
            ) { [weak self] in
                self?.handleStyleButton(mode: mode)
            }
            styleStack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: styleStack.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: styleStack.trailingAnchor),
            ])
        }

        if !workflows.isEmpty {
            let divider = makeBubbleControlDivider(dark: dark)
            stack.addArrangedSubview(divider)
            NSLayoutConstraint.activate([
                divider.heightAnchor.constraint(equalToConstant: 1),
                divider.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
                divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            ])
        }

        stack.addArrangedSubview(styleStack)
        NSLayoutConstraint.activate([
            styleStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            styleStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        let stopButton = makeBubbleControlButton(
            title: "Stop dictation",
            symbolName: "stop.circle.fill",
            emphasized: true,
            dark: dark
        ) { [weak self] in
            self?.handleStopDictationButton()
        }
        stack.addArrangedSubview(stopButton)
        NSLayoutConstraint.activate([
            stopButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            stopButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        return root
    }

    private static func controlStyleTitle(for mode: StructureMode) -> String {
        switch mode {
        case .natural:
            return "Natural"
        case .paragraph:
            return "Paragraph"
        case .bullets:
            return "Bullets"
        case .email:
            return "Email"
        case .command:
            return "Command"
        }
    }

    private func makeBubbleControlSectionLabel(_ title: String, dark: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.controlMenuFont(size: 11, weight: .semibold)
        label.textColor = Self.menuTextSecondaryColor(dark: dark)
        label.alignment = .left
        return label
    }

    private func makeBubbleControlButton(
        title: String,
        symbolName: String,
        emphasized: Bool,
        dark: Bool,
        onClick: @escaping @MainActor () -> Void
    ) -> BubbleControlMenuButton {
        let textColor: NSColor = emphasized
            ? Self.warmAccentText
            : Self.menuTextPrimaryColor(dark: dark)
        let iconColor: NSColor = emphasized
            ? Self.warmAccentText
            : (dark ? Self.accentCyan : Self.accentBlue)
        let backgroundColor: NSColor = emphasized
            ? Self.warmAccentFill.withAlphaComponent(dark ? 0.88 : 1.0)
            : .clear
        let borderColor: NSColor = emphasized
            ? Self.warmAccentText.withAlphaComponent(0.14)
            : .clear
        let hoverBackgroundColor = emphasized
            ? Self.warmAccentFill.withAlphaComponent(dark ? 0.80 : 0.90)
            : (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05))
        let pressedBackgroundColor = emphasized
            ? Self.warmAccentFill.withAlphaComponent(dark ? 0.72 : 0.82)
            : (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08))

        return BubbleControlMenuButton(
            title: title,
            symbolName: symbolName,
            font: Self.controlMenuFont(size: 13, weight: emphasized ? .semibold : .medium),
            titleColor: textColor,
            iconColor: iconColor,
            backgroundColor: backgroundColor,
            hoverBackgroundColor: hoverBackgroundColor,
            pressedBackgroundColor: pressedBackgroundColor,
            borderColor: borderColor,
            onClick: onClick
        )
    }

    private func makeBubbleControlDivider(dark: Bool) -> NSView {
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.cornerRadius = 0.5
        divider.layer?.backgroundColor = Self.menuBorderColor(dark: dark)
            .withAlphaComponent(dark ? 0.34 : 0.12)
            .cgColor
        return divider
    }

    private func makeBubbleControlSectionCard(content: NSStackView, dark: Bool) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0
        card.layer?.borderColor = NSColor.clear.cgColor
        card.layer?.backgroundColor = Self.menuSurfaceSecondaryColor(dark: dark).withAlphaComponent(dark ? 0.72 : 0.78).cgColor

        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
        ])

        return card
    }

    private static func controlMenuFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont(name: "Manrope", size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    private func controlMenuFrame(
        size: NSSize,
        bubbleScreenRect: NSRect,
        screen: NSScreen?
    ) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? bubbleScreenRect
        let gap: CGFloat = 12
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - size.width - 8
        let x = min(max(bubbleScreenRect.midX - (size.width / 2), minX), maxX)
        var y = bubbleScreenRect.maxY + gap
        if y + size.height > visibleFrame.maxY - 8 {
            y = bubbleScreenRect.minY - size.height - gap
        }
        y = min(max(y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func installBubbleControlMenuEventMonitors() {
        removeBubbleControlMenuEventMonitors()

        controlMenuLocalEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                Task { @MainActor in
                    self.hideBubbleControlMenu(animated: true)
                }
                return nil
            }

            if event.window !== self.controlMenuWindow,
               event.window !== self.window {
                Task { @MainActor in
                    self.hideBubbleControlMenu(animated: true)
                }
            }

            return event
        }

        controlMenuGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let mouseLocation = NSEvent.mouseLocation
                if self?.controlMenuWindow?.frame.contains(mouseLocation) == true ||
                    self?.window?.frame.contains(mouseLocation) == true {
                    return
                }
                self?.hideBubbleControlMenu(animated: true)
            }
        }
    }

    private func removeBubbleControlMenuEventMonitors() {
        if let controlMenuLocalEventMonitor {
            NSEvent.removeMonitor(controlMenuLocalEventMonitor)
            self.controlMenuLocalEventMonitor = nil
        }
        if let controlMenuGlobalEventMonitor {
            NSEvent.removeMonitor(controlMenuGlobalEventMonitor)
            self.controlMenuGlobalEventMonitor = nil
        }
    }

    private func hideBubbleControlMenu(animated: Bool) {
        removeBubbleControlMenuEventMonitors()
        guard let controlMenuWindow else { return }
        self.controlMenuWindow = nil
        let parentWindow = controlMenuWindow.parent

        guard animated, !reduceMotion else {
            parentWindow?.removeChildWindow(controlMenuWindow)
            controlMenuWindow.orderOut(nil)
            return
        }

        let finalFrame = controlMenuWindow.frame.offsetBy(dx: 0, dy: -8)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            controlMenuWindow.animator().alphaValue = 0
            controlMenuWindow.animator().setFrame(finalFrame, display: true)
        } completionHandler: {
            Task { @MainActor in
                parentWindow?.removeChildWindow(controlMenuWindow)
                controlMenuWindow.orderOut(nil)
            }
        }
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
        processingVideoLayer?.frame = rect
        scrimLayer?.frame = rect
        glassTintLayer?.frame = rect
        sheenLayer?.frame = rect
        CATransaction.commit()
    }

    private func updateOverlayFrames(for bubbleSize: NSSize, audioLevel: Double) {
        updateBorderGradientFrame(for: bubbleSize)
        updateProcessingIndicatorFrame(in: bubbleSize)
        updateProcessingRunnerFrame(in: bubbleSize)
        updateMeterBarFrames(
            level: audioLevel,
            in: CGRect(origin: .zero, size: bubbleSize)
        )
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
        startMeterBars()
    }

    private func startTranscribingPulse() {
        guard activePulseMode != .transcribing else { return }
        stopDotPulse()
        activePulseMode = .transcribing
        if bubbleAppearance != .techMeter {
            playProcessingVideoIfNeeded()
        }
        addProcessingIndicatorAnimation()
    }

    private func stopDotPulse() {
        stopProcessingVideo()
        processingIndicatorLayer?.removeAllAnimations()
        processingIndicatorLayer?.opacity = 0.0
        stopTechProcessingRunnerAnimation()
        setMeterVisible(false)
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

    private func playProcessingVideoIfNeeded() {
        guard let videoLayer = processingVideoLayer else { return }
        guard let url = Self.loadProcessingVideoURL(isDark: prefersDarkProcessingVideo) else {
            return
        }

        if processingPlayer == nil || processingPlayerURL != url {
            removeProcessingObservers()
            processingPlayer?.pause()

            let asset = AVAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            processingPlayer = player
            processingPlayerURL = url
            videoLayer.player = player
            installProcessingBoundaryObserver()
        }

        processingPlayer?.rate = 1.0
        processingPlayer?.seek(to: .zero)
        processingPlayer?.play()
    }

    private func stopProcessingVideo() {
        processingPlayer?.pause()
    }

    private var prefersDarkProcessingVideo: Bool {
        resolvedBubbleIsDark
    }

    private var resolvedBubbleIsDark: Bool {
        switch bubbleAppearance {
        case .dark, .techMeter:
            return true
        case .light:
            return false
        case .matchApp:
            break
        }
        if let override = prefersDarkAppearance {
            return override
        }
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var bubbleTextColor: NSColor {
        resolvedBubbleIsDark
            ? NSColor(red: 0.92, green: 0.95, blue: 0.96, alpha: 0.90)
            : NSColor(calibratedWhite: 0.20, alpha: 0.85)
    }

    private var bubbleBorderColor: NSColor {
        resolvedBubbleIsDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.50)
    }

    private var meterBarColor: NSColor {
        switch bubbleAppearance {
        case .techMeter:
            return Self.techAccent
        case .dark:
            return Self.accentCyan
        case .light:
            return NSColor(red: 0.36, green: 0.52, blue: 0.58, alpha: 1.0)
        case .matchApp:
            return resolvedBubbleIsDark
                ? Self.accentCyan
                : NSColor(red: 0.36, green: 0.52, blue: 0.58, alpha: 1.0)
        }
    }

    private var resolvedTextShadow: NSShadow? {
        bubbleAppearance == .techMeter ? nil : textShadow
    }

    private func bubbleSurfaceColor(lightAlpha: CGFloat, darkAlpha: CGFloat) -> NSColor {
        resolvedBubbleIsDark
            ? NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: darkAlpha)
            : NSColor.white.withAlphaComponent(lightAlpha)
    }

    private func neutralSurfaceColor(lightAlpha: CGFloat, darkAlpha: CGFloat) -> NSColor {
        resolvedBubbleIsDark
            ? NSColor.black.withAlphaComponent(darkAlpha)
            : NSColor.white.withAlphaComponent(lightAlpha)
    }

    private func refreshSurfaceAssets() {
        if let cgImage = Self.loadBlurredBackgroundImage(isDark: prefersDarkProcessingVideo) {
            backgroundImageLayer?.contents = cgImage
        }
        if let cgImage = Self.loadBackgroundCGImage(isDark: prefersDarkProcessingVideo) {
            revealedBackgroundImageLayer?.contents = cgImage
        }
        processingPlayerURL = nil
        processingPlayer?.pause()
    }

    private func applyAppearanceForCurrentState() {
        switch activePulseMode {
        case .listening:
            applyDefaultSurfaceAppearance()
        case .transcribing:
            applyTranscribingSurfaceAppearance()
        case .none:
            applyDefaultSurfaceAppearance()
        }
    }

    /// Observe both ends of the video so we can ping-pong playback
    /// (forward → reverse → forward …) for a seamless loop.
    private func installProcessingBoundaryObserver() {
        guard let player = processingPlayer else { return }
        removeProcessingObservers()

        processingBoundaryObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleProcessingVideoReachedEnd()
            }
        }

        // Also observe when reverse playback reaches the start.
        processingTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak player, weak self] time in
            guard let player, player.rate < 0, time <= .zero else { return }
            Task { @MainActor [weak self] in
                self?.handleProcessingVideoReachedStart()
            }
        }
    }

    private func removeProcessingObservers() {
        if let observer = processingBoundaryObserver {
            NotificationCenter.default.removeObserver(observer)
            processingBoundaryObserver = nil
        }

        if let observer = processingTimeObserver {
            processingPlayer?.removeTimeObserver(observer)
            processingTimeObserver = nil
        }
    }

    private func handleProcessingVideoReachedEnd() {
        guard let player = processingPlayer else { return }
        // Reverse playback from the end.
        player.rate = -1.0
    }

    private func handleProcessingVideoReachedStart() {
        guard let player = processingPlayer else { return }
        // Forward playback from the start.
        player.seek(to: .zero)
        player.rate = 1.0
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

        centerWindowAtBottom()
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

    private func centerWindowAtBottom() {
        guard let window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 12
        let x = screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2
        let y = screenFrame.origin.y + margin
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func loadBackgroundImage(isDark: Bool) -> NSImage? {
        if let image = resolvedBackgroundAssetImage(isDark: isDark) {
            return image
        }

        let resourceName = isDark ? "record-background-dark" : "record-background"
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png") {
            return NSImage(contentsOf: url)
        }

        if !isDark,
           let url = Bundle.main.url(forResource: "record-background", withExtension: "png") {
            return NSImage(contentsOf: url)
        }

        #if DEBUG
        let debugCandidates = isDark
            ? ["/tmp/record-background-dark.png", "/tmp/record-background.png"]
            : ["/tmp/record-background.png"]
        for path in debugCandidates where FileManager.default.fileExists(atPath: path) {
            return NSImage(contentsOfFile: path)
        }
        #endif

        return nil
    }

    private static func loadBackgroundCGImage(isDark: Bool) -> CGImage? {
        guard let image = loadBackgroundImage(isDark: isDark) else { return nil }
        var cgImage: CGImage?
        withBackgroundDrawingAppearance(isDark: isDark) {
            cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return cgImage
    }

    private static func loadProcessingVideoURL(isDark: Bool) -> URL? {
        if isDark,
           let darkURL = Bundle.main.url(forResource: "processing-background-dark", withExtension: "mp4") {
            return darkURL
        }
        if let url = Bundle.main.url(forResource: "processing-background", withExtension: "mp4") {
            return url
        }
        #if DEBUG
        let debugCandidates = isDark
            ? [
                "/tmp/processing-background-dark.mp4",
                "/Users/hannahwright/Documents/Code/Voce/Voce/processing-background-dark.mp4",
                "/Users/hannahwright/Code/Voce/Voce/processing-background-dark.mp4",
              ]
            : [
                "/tmp/processing-background.mp4",
                "/Users/hannahwright/Documents/Code/Voce/Voce/processing-background.mp4",
                "/Users/hannahwright/Code/Voce/Voce/processing-background.mp4",
              ]
        for devPath in debugCandidates where FileManager.default.fileExists(atPath: devPath) {
            return URL(fileURLWithPath: devPath)
        }
        #endif
        return nil
    }

    private static func loadBlurredBackgroundImage(isDark: Bool) -> CGImage? {
        guard let cgImage = loadBackgroundCGImage(isDark: isDark) else { return nil }

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

    private static func resolvedBackgroundAssetImage(isDark: Bool) -> NSImage? {
        var image: NSImage?
        withBackgroundDrawingAppearance(isDark: isDark) {
            image = NSImage(named: "RecordBackground")
        }
        return image
    }

    private static func withBackgroundDrawingAppearance(isDark: Bool, body: () -> Void) {
        guard let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) else {
            body()
            return
        }

        appearance.performAsCurrentDrawingAppearance(body)
    }

    private func endInteractiveRepositionMode(notify: Bool = true) {
        repositionModeTask?.cancel()
        repositionModeTask = nil
        repositionModeEnabled = false
        hitTestCanvasView?.acceptsBubbleInteraction = bubbleControlsEnabled
        window?.isMovableByWindowBackground = false
        if notify {
            notifyDragIfNeeded()
        }
    }

    private func notifyDragIfNeeded() {
        guard userDidDrag, let position = userDraggedPosition else { return }
        userDidDrag = false
        sessionPinnedOrigin = position
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
