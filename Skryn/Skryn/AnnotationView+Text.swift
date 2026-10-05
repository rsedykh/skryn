import AppKit

/// Text annotations: typing at the cursor (T), re-editing on click, font size (⌘= / ⌘-), the UTC
/// timestamp (U), and turning the text view back into an annotation.
extension AnnotationView {
    /// Opens a text editor at the cursor. Over an existing text annotation, edits that one instead.
    func startTextAtCursor(keyCode: UInt16) {
        guard let window else { return }
        let point = viewToScreenshot(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let index: Int?
        switch hitTestAnnotations(at: point) {
        case .handle(let i, _), .body(let i): index = i
        case .none: index = nil
        }
        if let index, case .text = annotations[index] {
            startEditingTextAnnotation(at: index)
        } else {
            placeTextAnnotation(at: point)
        }
        if case .editingText(let textView as IsolatedUndoTextView, _) = interactionState {
            textView.swallowsRepeatOfKeyCode = keyCode
        }
    }

    func placeTextAnnotation(at screenshotPoint: CGPoint) {
        let scale = screenshotToViewScale()
        let viewOrigin = screenshotToView(screenshotPoint)
        let viewWidth = 300 * scale
        let viewFontSize = textFontSize * scale

        let frame = CGRect(x: viewOrigin.x, y: viewOrigin.y, width: viewWidth, height: viewFontSize * 1.5)
        let textView = createTextView(frame: frame, fontSize: viewFontSize)
        addSubview(textView)
        dismissHint()
        interactionState = .editingText(textView: textView, existingIndex: nil)
        window?.makeFirstResponder(textView)
    }

    func startEditingTextAnnotation(at index: Int) {
        guard case .text(let origin, let width, let content, let fontSize, let color) = annotations[index]
        else { return }
        drawingColor = color
        let scale = screenshotToViewScale()
        let viewOrigin = screenshotToView(origin)
        let viewWidth = width * scale
        let viewFontSize = fontSize * scale

        let rect = Annotation.textBoundingRect(
            origin: origin, width: width, content: content, fontSize: fontSize
        )
        let viewHeight = rect.height * scale

        let frame = CGRect(x: viewOrigin.x, y: viewOrigin.y, width: viewWidth, height: viewHeight)
        let textView = createTextView(frame: frame, fontSize: viewFontSize)
        textView.string = content
        addSubview(textView)
        interactionState = .editingText(textView: textView, existingIndex: index)
        textFontSize = fontSize
        window?.makeFirstResponder(textView)
        needsDisplay = true
    }

    func createTextView(frame: CGRect, fontSize: CGFloat) -> NSTextView {
        let textView = IsolatedUndoTextView(frame: frame)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)

        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let textColor = drawingColor.nsColor
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.typingAttributes = [.font: font, .foregroundColor: textColor]

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        textView.delegate = self
        return textView
    }

    func finalizeTextEditing() {
        guard case .editingText(let textView, let existingIndex) = interactionState else { return }
        let content = textView.string
        let viewFrame = textView.frame

        textView.removeFromSuperview()
        interactionState = .idle
        window?.makeFirstResponder(self)

        // Convert view frame back to screenshot coords
        let scale = screenshotToViewScale()
        let screenshotOrigin = viewToScreenshot(CGPoint(x: viewFrame.minX, y: viewFrame.minY))
        let screenshotWidth = viewFrame.width / scale

        if let idx = existingIndex {
            if content.isEmpty {
                removeAnnotation(at: idx)
            } else {
                let newAnnotation = Annotation.text(
                    origin: screenshotOrigin, width: screenshotWidth,
                    content: content, fontSize: textFontSize, color: drawingColor
                )
                let old = annotations[idx]
                replaceAnnotation(at: idx, with: newAnnotation, old: old)
            }
        } else {
            if !content.isEmpty {
                let annotation = Annotation.text(
                    origin: screenshotOrigin, width: screenshotWidth,
                    content: content, fontSize: textFontSize, color: drawingColor
                )
                addAnnotation(annotation)
            }
        }

        NSCursor.arrow.set()
        needsDisplay = true
    }

    func insertTimestamp() {
        guard let window = window else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        let screenshotPoint = viewToScreenshot(viewPoint)

        let timestamp = Self.utcTimestampFormatter.string(from: captureDate)

        let font = NSFont.boldSystemFont(ofSize: textFontSize)
        let textWidth = (timestamp as NSString).size(withAttributes: [.font: font]).width + 4

        let annotation = Annotation.text(
            origin: screenshotPoint, width: textWidth,
            content: timestamp, fontSize: textFontSize, color: drawingColor
        )
        addAnnotation(annotation)
        needsDisplay = true
    }

    private static let utcTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter
    }()

    func adjustFontSize(larger: Bool) {
        let newSize = Annotation.steppedFontSize(textFontSize, larger: larger)
        textFontSize = newSize
        guard case .editingText(let textView, _) = interactionState else { return }
        let scale = screenshotToViewScale()
        let viewFontSize = newSize * scale
        let font = NSFont.boldSystemFont(ofSize: viewFontSize)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: drawingColor.nsColor]
        // Re-apply font to all existing text
        if !textView.string.isEmpty {
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.textStorage?.addAttribute(.font, value: font, range: range)
        }
        needsDisplay = true
    }
}

// MARK: - NSTextViewDelegate

extension AnnotationView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            finalizeTextEditing()
            return true
        }
        if selector == #selector(cancelOperation(_:)) {
            finalizeTextEditing()
            return true
        }
        return false
    }
}
