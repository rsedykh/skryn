import AppKit

/// Text annotations: typing at the cursor (T), re-editing on click, the text style (format bar,
/// ⌘= / ⌘- size, ⌘B bold), the UTC timestamp (U), and turning the text view back into an annotation.
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

        let frame = CGRect(x: viewOrigin.x, y: viewOrigin.y, width: viewWidth, height: textStyle.size * scale * 1.5)
        let textView = createTextView(frame: frame)
        addSubview(textView)
        dismissHint()
        interactionState = .editingText(textView: textView, existingIndex: nil)
        window?.makeFirstResponder(textView)
        showTextFormatBar(over: textView)
    }

    func startEditingTextAnnotation(at index: Int) {
        guard case .text(let origin, let width, let content, let style, let color) = annotations[index]
        else { return }
        drawingColor = color
        textStyle = style  // re-editing picks up the text's style, and new text continues with it
        let scale = screenshotToViewScale()
        let viewOrigin = screenshotToView(origin)
        let viewWidth = width * scale

        let rect = Annotation.textBoundingRect(origin: origin, width: width, content: content, style: style)
        let viewHeight = rect.height * scale

        let frame = CGRect(x: viewOrigin.x, y: viewOrigin.y, width: viewWidth, height: viewHeight)
        let textView = createTextView(frame: frame)
        textView.string = content
        styleTextView(textView)
        addSubview(textView)
        interactionState = .editingText(textView: textView, existingIndex: index)
        window?.makeFirstResponder(textView)
        showTextFormatBar(over: textView)
        needsDisplay = true
    }

    func createTextView(frame: CGRect) -> NSTextView {
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

        styleTextView(textView)

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
        textFormatBar?.hide()
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
                    content: content, style: textStyle, color: drawingColor
                )
                let old = annotations[idx]
                replaceAnnotation(at: idx, with: newAnnotation, old: old)
            }
        } else {
            if !content.isEmpty {
                let annotation = Annotation.text(
                    origin: screenshotOrigin, width: screenshotWidth,
                    content: content, style: textStyle, color: drawingColor
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

        let textWidth = (timestamp as NSString).size(withAttributes: [.font: textStyle.font]).width + 4

        let annotation = Annotation.text(
            origin: screenshotPoint, width: textWidth,
            content: timestamp, style: textStyle, color: drawingColor
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

    // MARK: Style

    /// Changes the text style (format bar, ⌘= / ⌘-, ⌘B): restyles the text being typed, and new text
    /// continues with it. Stored on the annotation when editing finishes (undoable then, as edits are).
    func updateTextStyle(_ change: (inout TextStyle) -> Void) {
        change(&textStyle)
        if case .editingText(let textView, _) = interactionState {
            styleTextView(textView)
            textFormatBar?.show(over: textView)  // its size or position may have changed
        }
        textFormatBar?.refresh()
        needsDisplay = true
    }

    func stepTextSize(larger: Bool) {
        updateTextStyle { $0.size = Annotation.steppedFontSize($0.size, larger: larger) }
    }

    /// The live text view in `textStyle` and the drawing color, at the zoomed size
    func styleTextView(_ textView: NSTextView) {
        let font = textStyle.font(ofSize: textStyle.size * screenshotToViewScale())
        let color = textStyle.textColor(on: drawingColor)
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: storage.length))
        }
    }

    func showTextFormatBar(over textView: NSTextView) {
        let bar = textFormatBar ?? TextFormatBar(editor: self)
        textFormatBar = bar
        bar.show(over: textView)
    }
}

// MARK: - NSTextViewDelegate

extension AnnotationView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if case .editingText(let textView, _) = interactionState { textFormatBar?.show(over: textView) }
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
