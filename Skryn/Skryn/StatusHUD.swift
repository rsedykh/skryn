import AppKit

/// How a confirmation reads: shared by the HUD (`StatusHUD`) and notifications (`Notifier`).
enum FeedbackStyle { case success, failure, info }

/// Immediate confirmation of what the user just did ("Copied", "Saved to Desktop"): a compact HUD capsule
/// in the toolbar's look, near the bottom of the screen under the pointer like a system toast, gone after
/// a moment. Needs no permission and Focus doesn't hide it, unlike notifications (`Notifier`), which carry
/// results that arrive later or need a button.
@MainActor
enum StatusHUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    /// Bumped on every show, so a stale hide doesn't order out a HUD that replaced it
    private static var generation = 0

    private static let iconSize: CGFloat = 26
    private static let maxTextWidth: CGFloat = 360
    /// Gap between the HUD and the bottom of the visible frame (above the Dock)
    private static let bottomMargin: CGFloat = 72

    /// True while the HUD is on screen (hiding the app would hide it too)
    static var isShowing: Bool { panel?.isVisible == true }

    /// Shows the HUD, morphing in place from one already on screen. `symbol` overrides the style's icon.
    static func show(_ message: String, detail: String? = nil, symbol: String? = nil, style: FeedbackStyle = .success) {
        hideWork?.cancel()
        generation += 1
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let surface = panel.contentView else { return }

        let content = makeContent(message: message, detail: detail, symbol: symbol, style: style)
        let size = content.fittingSize
        let frame = targetFrame(for: size)
        let replacing = panel.isVisible
        swapContent(of: surface, to: content, animated: replacing)
        setRadius(of: surface, to: detail == nil ? size.height / 2 : 16, animated: replacing)

        if replacing {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = HUDMotion.enterDuration
                context.timingFunction = HUDMotion.enterTiming
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }, completionHandler: { MainActor.assumeIsolated { panel.invalidateShadow() } })
        } else {
            panel.setFrame(frame, display: false)
            HUDMotion.show(panel, travel: .up, distance: 10, scale: 0.96) { panel.invalidateShadow() }
        }
        popIcon(in: content, delay: replacing ? 0.02 : 0.08)
        announce([message, detail].compactMap { $0 }.joined(separator: ". "), from: panel)

        let shown = generation
        let work = DispatchWorkItem { hide(panel, generation: shown) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail == nil ? 1.4 : 2.4), execute: work)
    }

    private static func hide(_ panel: NSPanel, generation shown: Int) {
        HUDMotion.hide(panel, travel: .up, distance: 6, scale: 0.98) {
            if generation == shown { panel.orderOut(nil) }
        }
    }

    private static func announce(_ text: String, from element: Any) {
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: - Layout

    /// Centered on the screen under the pointer, just above the Dock
    private static func targetFrame(for size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        return NSRect(
            x: round(visible.midX - size.width / 2), y: round(visible.minY + bottomMargin),
            width: ceil(size.width), height: ceil(size.height)
        )
    }

    /// Crossfades the old content out and `content` in, both centered while the surface resizes
    private static func swapContent(of surface: NSView, to content: NSView, animated: Bool) {
        let old = surface.subviews
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
        ])
        guard animated else {
            old.forEach { $0.removeFromSuperview() }
            return
        }
        content.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HUDMotion.enterDuration
            context.timingFunction = HUDMotion.enterTiming
            content.animator().alphaValue = 1
            old.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { MainActor.assumeIsolated { old.forEach { $0.removeFromSuperview() } } })
    }

    private static func setRadius(of surface: NSView, to radius: CGFloat, animated: Bool) {
        guard let layer = surface.layer, layer.cornerRadius != radius else { return }
        if animated && !HUDMotion.reduceMotion {
            let animation = CABasicAnimation(keyPath: "cornerRadius")
            animation.fromValue = layer.presentation()?.cornerRadius ?? layer.cornerRadius
            animation.duration = HUDMotion.enterDuration
            animation.timingFunction = HUDMotion.enterTiming
            layer.add(animation, forKey: "cornerRadius")
        }
        layer.cornerRadius = radius
    }

    /// The icon springs from 0.6 to full size just after the capsule lands
    private static func popIcon(in content: NSView, delay: TimeInterval) {
        guard !HUDMotion.reduceMotion,
              let layer = content.subviews.first(where: { $0.identifier == iconID })?.layer else { return }
        let center = iconSize / 2
        var from = CATransform3DMakeTranslation(center, center, 0)
        from = CATransform3DScale(from, 0.6, 0.6, 1)
        from = CATransform3DTranslate(from, -center, -center, 0)
        let begin = CACurrentMediaTime() + delay

        let scale = CASpringAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: from)
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.stiffness = 420
        scale.damping = 17
        scale.duration = scale.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        for animation in [scale, fade] as [CAAnimation] {
            animation.beginTime = begin
            animation.fillMode = .backwards
            layer.add(animation, forKey: animation === scale ? "pop" : "popFade")
        }
    }

    // MARK: - Views

    private static let iconID = NSUserInterfaceItemIdentifier("StatusHUD.icon")

    private static func tint(for style: FeedbackStyle) -> NSColor {
        switch style {
        case .success: NSColor(srgbRed: 0.45, green: 0.88, blue: 0.56, alpha: 1)
        case .failure: NSColor(srgbRed: 1, green: 0.64, blue: 0.32, alpha: 1)
        case .info: NSColor.white.withAlphaComponent(0.85)
        }
    }

    private static func defaultSymbol(for style: FeedbackStyle) -> String {
        switch style {
        case .success: "checkmark"
        case .failure: "exclamationmark"
        case .info: "info"
        }
    }

    /// Icon in a softly tinted circle; its leading inset matches the vertical one so it nests in the capsule
    private static func makeContent(message: String, detail: String?, symbol: String?, style: FeedbackStyle) -> NSView {
        let tint = tint(for: style)
        let isDefault = symbol == nil
        let image = NSImage(systemSymbolName: symbol ?? defaultSymbol(for: style), accessibilityDescription: nil)
        let icon = NSImageView(image: image ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: isDefault ? 12 : 13, weight: isDefault ? .bold : .semibold)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSView()
        badge.identifier = iconID
        badge.wantsLayer = true
        badge.layer?.backgroundColor = tint.withAlphaComponent(style == .info ? 0.14 : 0.2).cgColor
        badge.layer?.cornerRadius = iconSize / 2
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: iconSize),
            badge.heightAnchor.constraint(equalToConstant: iconSize),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        let stack = NSStackView(views: [badge, makeText(message: message, detail: detail)])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        let vertical: CGFloat = detail == nil ? 11 : 12
        stack.edgeInsets = NSEdgeInsets(top: vertical, left: vertical, bottom: vertical, right: 18)
        return stack
    }

    private static func makeText(message: String, detail: String?) -> NSView {
        let title = label(message, font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        title.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [title]
        if let detail {
            let caption = label(detail, font: .systemFont(ofSize: 11.5), color: HUDStyle.dimmed)
            caption.lineBreakMode = .byTruncatingMiddle
            views.append(caption)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxTextWidth).isActive = true
        return stack
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func makePanel() -> NSPanel {
        let panel = HUDPanel()
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let surface = NSView()
        surface.wantsLayer = true
        HUDStyle.paintSurface(surface.layer)
        panel.contentView = surface
        return panel
    }
}
