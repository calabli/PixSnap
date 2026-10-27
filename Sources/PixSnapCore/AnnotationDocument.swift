import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Everything drawn on top of one screenshot, in canvas points with a top-left origin.
/// Annotations are ordered back to front.
public struct AnnotationDocument: Equatable, Sendable {
    public let canvasSize: CGSize
    public private(set) var annotations: [Annotation] = []
    /// The part of the canvas kept on export; nil keeps all of it.
    public private(set) var crop: CGRect?

    /// Crops smaller than this (in points) are treated as a click that clears the crop.
    public static let minimumCropSize: CGFloat = 4

    public init(canvasSize: CGSize) {
        self.canvasSize = canvasSize
    }

    public var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }
    public var outputRect: CGRect { crop ?? canvasRect }

    public func annotation(withID id: Annotation.ID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// The front-most annotation under `point`.
    public func annotation(at point: CGPoint, tolerance: CGFloat = 6) -> Annotation? {
        annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    /// Number markers keep counting up even after earlier ones are deleted.
    public var nextCounterNumber: Int {
        let numbers = annotations.compactMap { annotation -> Int? in
            if case .counter(let number, _) = annotation.shape { return number }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    public mutating func add(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    public mutating func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    public mutating func remove(id: Annotation.ID) {
        annotations.removeAll { $0.id == id }
    }

    public mutating func setCrop(_ rect: CGRect?) {
        guard let rect else {
            crop = nil
            return
        }
        let clipped = rect.standardized.intersection(canvasRect)
        let tooSmall = clipped.isNull || clipped.width < Self.minimumCropSize || clipped.height < Self.minimumCropSize
        crop = tooSmall ? nil : clipped
    }
}
