import AppKit

/// Draws the document and turns mouse and key input into edits.
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let model: EditorModel

    private enum Drag {
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case reshaping(UUID, movingStart: Bool)
        case cropping(CGPoint)
    }

    private var drag: Drag?
    private var liveCrop: CGRect?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var editedText: Annotation?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.onChange = { [weak self] in self?.needsDisplay = true }
        setAccessibilityLabel("Annotation canvas")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Points of view per image pixel, and where the image's top-left sits in the view.
    private var fit: (scale: CGFloat, origin: CGPoint) {
        let size = model.imageSize
        let pad = model.padding(for: size)
        // The background, when there is one, is part of what has to fit.
        let outer = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let margin: CGFloat = 16
        let available = CGSize(width: max(bounds.width - margin * 2, 1), height: max(bounds.height - margin * 2, 1))
        let s = min(available.width / outer.width, available.height / outer.height, 1 / model.scale * 2)
        return (s, CGPoint(x: (bounds.width - size.width * s) / 2, y: (bounds.height - size.height * s) / 2))
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let f = fit
        return CGPoint(x: (p.x - f.origin.x) / f.scale, y: (p.y - f.origin.y) / f.scale)
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), model.imageSize.width), y: min(max(p.y, 0), model.imageSize.height))
    }

    private var handleRadius: CGFloat { 5 / fit.scale }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let f = fit
        ctx.saveGState()
        ctx.translateBy(x: f.origin.x, y: f.origin.y)
        ctx.scaleBy(x: f.scale, y: f.scale)
        ctx.interpolationQuality = .high
        let pad = model.padding(for: model.imageSize)
        let hasBackdrop = model.backdrop != .none
        if hasBackdrop {
            // Preview of the background. With a crop, the export wraps the cropped area instead.
            model.drawBackdrop(in: CGRect(origin: .zero, size: model.imageSize).insetBy(dx: -pad, dy: -pad), context: ctx)
            ctx.saveGState()
            let radius = model.cornerRadius(for: model.imageSize)
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: model.imageSize), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
        }
        model.draw(in: ctx)
        if hasBackdrop { ctx.restoreGState() }

        let full = CGRect(origin: .zero, size: model.imageSize)
        if let crop = liveCrop ?? model.crop {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.addRect(full)
            ctx.addRect(crop)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1 / f.scale)
            ctx.stroke(crop)
        }

        if let item = model.selected {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1 / f.scale)
            ctx.setLineDash(phase: 0, lengths: [4 / f.scale, 3 / f.scale])
            ctx.stroke(item.bounds.insetBy(dx: -4 / f.scale, dy: -4 / f.scale))
            ctx.setLineDash(phase: 0, lengths: [])
            if item.hasEndpoints {
                for p in [item.start, item.end] {
                    let r = CGRect(x: p.x - handleRadius, y: p.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fillEllipse(in: r)
                    ctx.strokeEllipse(in: r)
                }
            }
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let p = imagePoint(event)
        let tolerance = 6 / fit.scale

        switch model.tool {
        case .select:
            if let item = model.selected, item.hasEndpoints {
                for (point, isStart) in [(item.start, true), (item.end, false)]
                where hypot(p.x - point.x, p.y - point.y) <= handleRadius * 1.8 {
                    model.checkpoint()
                    drag = .reshaping(item.id, movingStart: isStart)
                    return
                }
            }
            if let hit = model.hit(at: p, tolerance: tolerance) {
                model.selectedID = hit.id
                model.adoptStyle(of: hit)
                if event.clickCount == 2, hit.tool == .text {
                    beginText(at: hit.start, editing: hit)
                    return
                }
                model.checkpoint()
                drag = .moving(hit.id, last: p)
            } else {
                model.selectedID = nil
            }
        case .text:
            if let hit = model.hit(at: p, tolerance: tolerance), hit.tool == .text {
                beginText(at: hit.start, editing: hit)
            } else {
                beginText(at: clamped(p), editing: nil)
            }
        case .step:
            let item = Annotation(tool: .step, start: clamped(p), end: clamped(p), color: model.color, width: model.width, number: model.nextStepNumber)
            model.add(item)
            model.selectedID = nil
        case .crop:
            drag = .cropping(clamped(p))
            liveCrop = CGRect(origin: clamped(p), size: .zero)
        default:
            let start = clamped(p)
            var item = Annotation(tool: model.tool, start: start, end: start, color: model.color, width: model.width)
            if model.tool.isPath { item.points = [start] }
            model.checkpoint()
            model.appendLive(item)
            model.selectedID = nil
            drag = .creating(item.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        switch drag {
        case let .creating(id):
            guard var item = model.annotations.first(where: { $0.id == id }) else { return }
            item.end = clamped(p)
            if item.tool.isPath { item.points.append(clamped(p)) }
            if event.modifierFlags.contains(.shift) { constrain(&item) }
            model.update(item)
        case let .moving(id, last):
            guard var item = model.annotations.first(where: { $0.id == id }) else { return }
            item.translate(dx: p.x - last.x, dy: p.y - last.y)
            model.update(item)
            drag = .moving(id, last: p)
        case let .reshaping(id, movingStart):
            guard var item = model.annotations.first(where: { $0.id == id }) else { return }
            if movingStart { item.start = clamped(p) } else { item.end = clamped(p) }
            model.update(item)
        case let .cropping(start):
            let q = clamped(p)
            liveCrop = CGRect(x: min(start.x, q.x), y: min(start.y, q.y), width: abs(q.x - start.x), height: abs(q.y - start.y))
            needsDisplay = true
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case let .creating(id):
            guard let item = model.annotations.first(where: { $0.id == id }) else { return }
            // A click without a drag leaves nothing behind (and nothing to undo).
            let tiny = item.tool.isPath ? item.points.count < 2 : hypot(item.end.x - item.start.x, item.end.y - item.start.y) < 3
            if tiny { model.undo() }
        case .cropping:
            if let rect = liveCrop, rect.width >= 4, rect.height >= 4 {
                model.setCrop(rect)
            } else if model.crop != nil {
                model.setCrop(nil)
            }
            liveCrop = nil
            needsDisplay = true
        default:
            break
        }
    }

    /// Shift keeps lines at 45° steps and shapes square.
    private func constrain(_ item: inout Annotation) {
        let dx = item.end.x - item.start.x, dy = item.end.y - item.start.y
        switch item.tool {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            item.end = CGPoint(x: item.start.x + cos(angle) * length, y: item.start.y + sin(angle) * length)
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            item.end = CGPoint(x: item.start.x + (dx < 0 ? -side : side), y: item.start.y + (dy < 0 ? -side : side))
        default:
            break
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete
            if let id = model.selectedID { model.remove(id) }
        case 53: // esc
            model.selectedID = nil
        default:
            super.keyDown(with: event)
        }
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }

    // MARK: Text

    private func beginText(at origin: CGPoint, editing existing: Annotation?) {
        let f = fit
        let sample = existing ?? Annotation(tool: .text, start: origin, end: origin, color: model.color, width: model.width)
        let field = NSTextField(string: existing?.text ?? "")
        field.font = NSFont.systemFont(ofSize: sample.font.pointSize * f.scale, weight: .semibold)
        field.textColor = sample.color
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Text"
        field.setAccessibilityLabel("Annotation text")
        let height = ceil(field.font!.ascender - field.font!.descender + field.font!.leading) + 2
        field.frame = CGRect(
            x: f.origin.x + origin.x * f.scale - 2, y: f.origin.y + origin.y * f.scale,
            width: max(160, bounds.width - (f.origin.x + origin.x * f.scale) - 20), height: height
        )
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = origin
        editedText = existing
        if let existing {
            // Hide the original while its text is in the field.
            var hidden = existing
            hidden.text = ""
            model.update(hidden)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if let existing = editedText {
            editedText = nil
            model.update(existing) // put the original back so the checkpoint below captures it
            if string.isEmpty {
                model.remove(existing.id)
            } else if string != existing.text {
                model.checkpoint()
                var changed = existing
                changed.text = string
                model.update(changed)
            }
        } else if !string.isEmpty {
            model.add(Annotation(tool: .text, start: textOrigin, end: textOrigin, color: model.color, width: model.width, text: string))
        }
        window?.makeFirstResponder(self)
    }

    /// Finishes any in-progress text so exports include it.
    func finishEditing() { commitText() }
}
