#if os(macOS)
import AppKit
import ApplicationServices
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

    private static let axSelectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let axBoundsForTextMarkerRangeParameterizedAttribute = "AXBoundsForTextMarkerRange"
    private static let compactSize = NSSize(width: 260, height: 44)
    private static let transcriptSize = NSSize(width: 320, height: 84)

    public struct AnchorSnapshot: Sendable, Equatable {
        public let frame: CGRect

        public init(frame: CGRect) {
            self.frame = frame
        }
    }

    private var window: NSWindow?
    private var containerView: NSView?
    private var statusDot: NSView?
    private var dotGlowLayer: CALayer?
    private var borderGradientLayer: CAGradientLayer?
    private var statusTextField: NSTextField?
    private var transcriptScrollView: NSScrollView?
    private var transcriptTextView: NSTextView?
    private var timer: Timer?
    private var listeningStartDate: Date?
    private var listeningHandsFree = false
    private var pulseTimer: Timer?
    private var dotPulseHigh = true
    private var wasHidden = true
    private var anchorSnapshot: AnchorSnapshot?
    private var layoutMode: LayoutMode = .compact
    private var lastLiveTranscriptText: String = ""

    private static let dotBlue = NSColor(red: 0.32, green: 0.60, blue: 0.82, alpha: 1.0)
    private static let dotSkyBlue = NSColor(red: 0.62, green: 0.78, blue: 0.90, alpha: 1.0)
    private static let dotLavender = NSColor(red: 0.72, green: 0.70, blue: 0.84, alpha: 1.0)

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
            pulseTimer?.invalidate()
            pulseTimer = nil
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

    public func show(state: OverlayState) {
        ensureWindow()

        let isFirstShow = wasHidden
        wasHidden = false

        switch state {
        case .listening(let handsFree, _):
            applyLayout(.transcript)
            listeningHandsFree = handsFree
            listeningStartDate = Date()
            lastLiveTranscriptText = ""
            updateTranscript("Transcribing…")
            stopTimer()
            animateDotColor(Self.dotBlue)
            resetBorderToAccent()
            startDotPulse()

        case .liveTranscript(let text, _):
            applyLayout(.transcript)
            stopTimer()
            lastLiveTranscriptText = text
            updateTranscript(text)
            animateDotColor(Self.dotBlue)
            resetBorderToAccent()
            startDotPulse()

        case .transcribing:
            stopTimer()
            applyLayout(.transcript)
            updateTranscript(lastLiveTranscriptText.isEmpty ? "Transcribing…" : lastLiveTranscriptText)
            animateDotColor(.systemOrange)
            updateBorderColors(for: .systemOrange)
            startDotPulse()

        case .inserted:
            applyLayout(.compact)
            stopTimer()
            stopDotPulse()
            updateText("Inserted")
            animateDotColor(.systemGreen)
            updateBorderColors(for: .systemGreen)
            playSuccessBounce()

        case .copiedOnly:
            applyLayout(.compact)
            stopTimer()
            stopDotPulse()
            updateText("Copied to clipboard")
            animateDotColor(.systemOrange)
            updateBorderColors(for: .systemOrange)

        case .failure(let message):
            applyLayout(.compact)
            stopTimer()
            stopDotPulse()
            updateText("Error: \(message)")
            animateDotColor(.systemRed)
            updateBorderColors(for: .systemRed)
        }

        positionWindow()

        if isFirstShow && !reduceMotion {
            // Entrance animation: fade in + slide up + gentle scale
            window?.alphaValue = 0
            let finalOrigin = window?.frame.origin ?? .zero
            window?.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 12))
            containerView?.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            window?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) // spring-like
                self.window?.animator().alphaValue = 1
                self.window?.animator().setFrameOrigin(finalOrigin)
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
            containerView?.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        } else {
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

        let contentRect = NSRect(origin: .zero, size: Self.compactSize)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // Glass background with vibrancy
        let vibrancy = NSVisualEffectView(frame: contentRect)
        vibrancy.material = .hudWindow
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = 22
        vibrancy.layer?.masksToBounds = true
        vibrancy.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor

        // Outer container for shadow + border (can't put shadow on clipped view)
        let container = NSView(frame: contentRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = 22
        container.layer?.masksToBounds = false
        self.containerView = container

        // Animated gradient border layer
        let borderGradient = CAGradientLayer()
        borderGradient.type = .conic
        borderGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        borderGradient.endPoint = CGPoint(x: 0.5, y: 0)
        borderGradient.colors = [
            Self.dotBlue.withAlphaComponent(0.5).cgColor,
            Self.dotSkyBlue.withAlphaComponent(0.3).cgColor,
            Self.dotLavender.withAlphaComponent(0.4).cgColor,
            Self.dotBlue.withAlphaComponent(0.5).cgColor
        ]
        borderGradient.frame = contentRect
        borderGradient.cornerRadius = 22

        // Mask the gradient to only show as a border ring
        let borderMask = CAShapeLayer()
        let outerPath = NSBezierPath(roundedRect: contentRect, xRadius: 22, yRadius: 22)
        let innerRect = contentRect.insetBy(dx: 1.0, dy: 1.0)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 21, yRadius: 21)
        outerPath.append(innerPath.reversed)
        borderMask.path = outerPath.cgPathFallback
        borderMask.fillRule = .evenOdd
        borderGradient.mask = borderMask
        container.layer?.addSublayer(borderGradient)
        self.borderGradientLayer = borderGradient

        // Ambient glow shadow — colored to match state
        container.layer?.shadowColor = Self.dotBlue.withAlphaComponent(0.35).cgColor
        container.layer?.shadowOffset = CGSize(width: 0, height: -1)
        container.layer?.shadowRadius = 24
        container.layer?.shadowOpacity = 1

        container.addSubview(vibrancy)
        vibrancy.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vibrancy.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vibrancy.topAnchor.constraint(equalTo: container.topAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Status dot — now a glowing orb
        let dot = NSView(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = Self.dotBlue.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        // Soft glow halo behind the dot
        let glowLayer = CALayer()
        glowLayer.backgroundColor = Self.dotBlue.withAlphaComponent(0.25).cgColor
        glowLayer.cornerRadius = 10
        glowLayer.frame = CGRect(x: -4, y: -4, width: 20, height: 20)
        glowLayer.shadowColor = Self.dotBlue.cgColor
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 8
        glowLayer.shadowOpacity = 0.6
        dot.layer?.addSublayer(glowLayer)
        self.dotGlowLayer = glowLayer

        vibrancy.addSubview(dot)
        self.statusDot = dot

        // Compact status text.
        let label = NSTextField(labelWithString: "Listening 00:00")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        vibrancy.addSubview(label)
        self.statusTextField = label

        // Transcript preview grows to three wrapped lines and follows the latest partials.
        let transcriptTextView = NSTextView(frame: .zero)
        transcriptTextView.drawsBackground = false
        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = false
        transcriptTextView.isVerticallyResizable = true
        transcriptTextView.isHorizontallyResizable = false
        transcriptTextView.textContainerInset = NSSize(width: 0, height: 1)
        transcriptTextView.font = .systemFont(ofSize: 13, weight: .medium)
        transcriptTextView.textColor = .labelColor
        transcriptTextView.alignment = .left
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
        vibrancy.addSubview(transcriptScrollView)
        self.transcriptTextView = transcriptTextView
        self.transcriptScrollView = transcriptScrollView

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: vibrancy.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: vibrancy.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: vibrancy.centerYAnchor),

            transcriptScrollView.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor, constant: 36),
            transcriptScrollView.trailingAnchor.constraint(equalTo: vibrancy.trailingAnchor, constant: -16),
            transcriptScrollView.topAnchor.constraint(equalTo: vibrancy.topAnchor, constant: 12),
            transcriptScrollView.bottomAnchor.constraint(equalTo: vibrancy.bottomAnchor, constant: -12)
        ])

        panel.contentView = container
        self.window = panel
    }

    private func animateDotColor(_ color: NSColor) {
        guard !reduceMotion else {
            statusDot?.layer?.backgroundColor = color.cgColor
            dotGlowLayer?.backgroundColor = color.withAlphaComponent(0.25).cgColor
            dotGlowLayer?.shadowColor = color.cgColor
            containerView?.layer?.shadowColor = color.withAlphaComponent(0.35).cgColor
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        statusDot?.layer?.backgroundColor = color.cgColor
        dotGlowLayer?.backgroundColor = color.withAlphaComponent(0.25).cgColor
        dotGlowLayer?.shadowColor = color.cgColor
        containerView?.layer?.shadowColor = color.withAlphaComponent(0.35).cgColor
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

    private func updateTranscript(_ text: String) {
        statusTextField?.isHidden = true
        transcriptScrollView?.isHidden = false
        transcriptTextView?.string = text
        transcriptTextView?.scrollToEndOfDocument(nil)
    }

    private func applyLayout(_ newLayout: LayoutMode) {
        guard let window, layoutMode != newLayout else {
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
        let targetSize = newLayout == .transcript ? Self.transcriptSize : Self.compactSize
        window.setContentSize(targetSize)
        updateBorderGradientFrame(for: targetSize)
        positionWindow()
        if newLayout == .transcript {
            statusTextField?.isHidden = true
            transcriptScrollView?.isHidden = false
        } else {
            statusTextField?.isHidden = false
            transcriptScrollView?.isHidden = true
        }
    }

    private func updateBorderGradientFrame(for size: NSSize) {
        guard let borderGradientLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = NSRect(origin: .zero, size: size)
        borderGradientLayer.frame = rect

        // Rebuild the border mask for the new size
        let borderMask = CAShapeLayer()
        let outerPath = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        let innerRect = rect.insetBy(dx: 1.0, dy: 1.0)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 21, yRadius: 21)
        outerPath.append(innerPath.reversed)
        borderMask.path = outerPath.cgPathFallback
        borderMask.fillRule = .evenOdd
        borderGradientLayer.mask = borderMask
        CATransaction.commit()
    }

    private func startDotPulse() {
        stopDotPulse()
        dotPulseHigh = true
        statusDot?.alphaValue = 1.0
        dotGlowLayer?.opacity = 1.0

        // Breathing glow animation on the halo
        let newTimer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dotPulseHigh.toggle()
                let targetOpacity: CGFloat = self.dotPulseHigh ? 1.0 : 0.35
                let glowScale: CGFloat = self.dotPulseHigh ? 1.0 : 0.7

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.9
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.statusDot?.animator().alphaValue = targetOpacity
                }

                // Glow layer breathes in/out
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.9)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
                self.dotGlowLayer?.opacity = Float(self.dotPulseHigh ? 0.8 : 0.2)
                self.dotGlowLayer?.transform = CATransform3DMakeScale(glowScale, glowScale, 1)
                // Ambient shadow breathes too
                self.containerView?.layer?.shadowRadius = self.dotPulseHigh ? 24 : 16
                self.containerView?.layer?.shadowOpacity = self.dotPulseHigh ? 1.0 : 0.5
                CATransaction.commit()
            }
        }
        RunLoop.current.add(newTimer, forMode: .common)
        pulseTimer = newTimer

        // Start the animated gradient border rotation
        startBorderAnimation()
    }

    private func stopDotPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusDot?.alphaValue = 1.0
        dotGlowLayer?.opacity = 1.0
        dotGlowLayer?.transform = CATransform3DIdentity
        containerView?.layer?.shadowRadius = 24
        containerView?.layer?.shadowOpacity = 1.0
        stopBorderAnimation()
    }

    private func startBorderAnimation() {
        guard !reduceMotion else { return }
        guard let borderGradientLayer else { return }
        guard borderGradientLayer.animation(forKey: "borderRotation") == nil else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 8
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        borderGradientLayer.add(rotation, forKey: "borderRotation")
    }

    private func stopBorderAnimation() {
        borderGradientLayer?.removeAnimation(forKey: "borderRotation")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderGradientLayer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func updateBorderColors(for color: NSColor) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        borderGradientLayer?.colors = [
            color.withAlphaComponent(0.5).cgColor,
            color.withAlphaComponent(0.2).cgColor,
            color.withAlphaComponent(0.35).cgColor,
            color.withAlphaComponent(0.5).cgColor
        ]
        CATransaction.commit()
    }

    private func resetBorderToAccent() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        borderGradientLayer?.colors = [
            Self.dotBlue.withAlphaComponent(0.5).cgColor,
            Self.dotSkyBlue.withAlphaComponent(0.3).cgColor,
            Self.dotLavender.withAlphaComponent(0.4).cgColor,
            Self.dotBlue.withAlphaComponent(0.5).cgColor
        ]
        CATransaction.commit()
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

        if let anchoredOrigin = anchoredWindowOrigin(for: window) {
            window.setFrameOrigin(anchoredOrigin)
            return
        }

        centerWindowNearTop()
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
