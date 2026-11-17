import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

public enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, freehand, text, step, highlighter, blur, pixelate, crop

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .freehand: return "Draw"
        case .text: return "Text"
        case .step: return "Numbered step"
        case .highlighter: return "Highlighter"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .freehand: return "scribble"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .highlighter: return "highlighter"
        case .blur: return "drop"
        case .pixelate: return "squareshape.split.3x3"
        case .crop: return "crop"
        }
    }

    var isPath: Bool { self == .freehand || self == .highlighter }
}

/// One editable object. All geometry is in image pixels with the origin at the top-left.
struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var text = ""
    var number = 0

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var font: NSFont { .systemFont(ofSize: max(10, width * 6), weight: .semibold) }
    var stepRadius: CGFloat { max(10, width * 4.5) }

    var bounds: CGRect {
        switch tool {
        case .freehand, .highlighter:
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for p in points { box = box.union(CGRect(origin: p, size: .zero)) }
            return box.insetBy(dx: -width, dy: -width)
        case .text:
            let size = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(origin: start, size: size)
        case .step:
            return CGRect(x: start.x - stepRadius, y: start.y - stepRadius, width: stepRadius * 2, height: stepRadius * 2)
        default:
            return rect
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
        let reach = tolerance + width / 2
        switch tool {
        case .arrow, .line:
            return distance(start, end) <= reach
        case .freehand, .highlighter:
            let r = tool == .highlighter ? reach + width * 2 : reach
            return zip(points, points.dropFirst()).contains { distance($0, $1) <= r }
        case .rectangle, .ellipse:
            // The outline, not the inside, so objects underneath stay reachable.
            return rect.insetBy(dx: -reach, dy: -reach).contains(p) && !rect.insetBy(dx: reach, dy: reach).contains(p)
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// Start/end objects can be reshaped by dragging either end.
    var hasEndpoints: Bool {
        switch tool {
        case .arrow, .line, .rectangle, .ellipse, .blur, .pixelate: return true
        default: return false
        }
    }
}

/// The document being edited: base image, objects, crop, and undo history.
final class EditorModel: ObservableObject {
    let image: CGImage
    let scale: CGFloat
    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

    @Published var tool: Tool = .arrow
    @Published var color: NSColor = .systemRed { didSet { applyStyleToSelection() } }
    @Published var width: CGFloat { didSet { applyStyleToSelection() } }
    @Published private(set) var annotations: [Annotation] = [] { didSet { onChange?() } }
    @Published private(set) var crop: CGRect? { didSet { onChange?() } }
    @Published var selectedID: UUID? { didSet { onChange?() } }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var onChange: (() -> Void)?

    private struct Snapshot {
        let annotations: [Annotation]
        let crop: CGRect?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var applyingSelectionStyle = false

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(scale, 1)
        width = 3 * max(scale, 1)
    }

    var selected: Annotation? { annotations.first { $0.id == selectedID } }
    var nextStepNumber: Int { (annotations.filter { $0.tool == .step }.map(\.number).max() ?? 0) + 1 }

    // MARK: Editing

    /// Records the current state so the next change can be undone.
    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoState()
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    /// Changes without a checkpoint, for use during a drag that already took one.
    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    func appendLive(_ annotation: Annotation) { annotations.append(annotation) }

    func remove(_ id: UUID, checkpoint take: Bool = true) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        if take { checkpoint() }
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func setCrop(_ rect: CGRect?) {
        checkpoint()
        crop = rect.map { $0.intersection(CGRect(origin: .zero, size: imageSize)).integral }
    }

    func hit(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.last { $0.hitTest(p, tolerance: tolerance) }
    }

    private func applyStyleToSelection() {
        guard !applyingSelectionStyle, var item = selected, item.color != color || item.width != width else { return }
        checkpoint()
        item.color = color
        item.width = width
        update(item)
    }

    /// Shows the selected object's colour and width in the toolbar without re-applying them.
    func adoptStyle(of item: Annotation) {
        applyingSelectionStyle = true
        color = item.color
        width = item.width
        applyingSelectionStyle = false
    }

    // MARK: Undo

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        crop = snapshot.crop
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = nil }
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Rendering

    private lazy var ciContext = CIContext()
    private lazy var blurred: CGImage? = filtered { input in
        let f = CIFilter.gaussianBlur()
        f.inputImage = input.clampedToExtent()
        f.radius = Float(12 * scale)
        return f.outputImage
    }
    private lazy var pixelated: CGImage? = filtered { input in
        let f = CIFilter.pixellate()
        f.inputImage = input.clampedToExtent()
        f.scale = Float(10 * scale)
        f.center = .zero
        return f.outputImage
    }

    private func filtered(_ make: (CIImage) -> CIImage?) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let output = make(input) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private func drawBase(_ source: CGImage, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: imageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(source, in: CGRect(origin: .zero, size: imageSize))
        ctx.restoreGState()
    }

    /// Draws the image and every object. `ctx` must be flipped (origin top-left) and in image pixels.
    func draw(in ctx: CGContext) {
        drawBase(image, in: ctx)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for item in annotations { draw(item, in: ctx) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ item: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        ctx.setLineWidth(item.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.tool {
        case .line:
            ctx.move(to: item.start)
            ctx.addLine(to: item.end)
            ctx.strokePath()
        case .arrow:
            let angle = atan2(item.end.y - item.start.y, item.end.x - item.start.x)
            let head = max(item.width * 4.5, 12)
            let length = hypot(item.end.x - item.start.x, item.end.y - item.start.y)
            let shaftEnd = length > head
                ? CGPoint(x: item.end.x - cos(angle) * head * 0.8, y: item.end.y - sin(angle) * head * 0.8)
                : item.start
            ctx.move(to: item.start)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.move(to: item.end)
            ctx.addLine(to: CGPoint(x: item.end.x - cos(angle - 0.45) * head, y: item.end.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: item.end.x - cos(angle + 0.45) * head, y: item.end.y - sin(angle + 0.45) * head))
            ctx.closePath()
            ctx.fillPath()
        case .rectangle:
            ctx.stroke(item.rect)
        case .ellipse:
            ctx.strokeEllipse(in: item.rect)
        case .freehand, .highlighter:
            guard let first = item.points.first else { return }
            if item.tool == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(item.color.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(item.width * 5)
                ctx.setLineCap(.butt)
            }
            ctx.move(to: first)
            for p in item.points.dropFirst() { ctx.addLine(to: p) }
            if item.points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            ctx.strokePath()
        case .text:
            (item.text as NSString).draw(at: item.start, withAttributes: [.font: item.font, .foregroundColor: item.color])
        case .step:
            ctx.fillEllipse(in: item.bounds)
            let label = "\(item.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: item.stepRadius * 1.1, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: item.start.x - size.width / 2, y: item.start.y - size.height / 2), withAttributes: attrs)
        case .blur, .pixelate:
            guard let source = item.tool == .blur ? blurred : pixelated else { return }
            ctx.clip(to: item.rect)
            drawBase(source, in: ctx)
        case .select, .crop:
            break
        }
    }

    /// The finished image at native pixel size, cropped if a crop is set.
    func render() -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: imageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx)
        guard let full = ctx.makeImage() else { return nil }
        if let crop, crop.width >= 1, crop.height >= 1 { return full.cropping(to: crop) }
        return full
    }
}
