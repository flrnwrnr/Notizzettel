import CoreGraphics
import PencilKit
import UIKit

/// PencilKit's drawing equality can reflect backing-object identity. Compare the public
/// stroke content that determines the rendered image instead, preserving stroke order.
enum RecognitionStrokeComparison {
    static func equal(_ lhs: [PKStroke], _ rhs: [PKStroke]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { equal($0.0, $0.1) }
    }

    private static func equal(_ lhs: PKStroke, _ rhs: PKStroke) -> Bool {
        guard lhs.ink.inkType == rhs.ink.inkType,
              equalColor(lhs.ink.color, rhs.ink.color),
              lhs.transform == rhs.transform,
              lhs.randomSeed == rhs.randomSeed,
              equalMask(lhs.mask, rhs.mask),
              lhs.path.creationDate == rhs.path.creationDate,
              lhs.path.count == rhs.path.count,
              newerStrokeFieldsEqual(lhs, rhs) else { return false }

        return zip(lhs.path, rhs.path).allSatisfy { a, b in
            a.location == b.location &&
                a.timeOffset == b.timeOffset &&
                a.size == b.size &&
                a.opacity == b.opacity &&
                a.force == b.force &&
                a.azimuth == b.azimuth &&
                a.altitude == b.altitude &&
                a.secondaryScale == b.secondaryScale &&
                pointNewerFieldsEqual(a, b)
        }
    }

    private static func newerStrokeFieldsEqual(_ lhs: PKStroke, _ rhs: PKStroke) -> Bool {
        if #available(iOS 27.0, *) {
            return lhs.renderGroupID == rhs.renderGroupID && lhs.renderState == rhs.renderState
        }
        return true
    }

    private static func pointNewerFieldsEqual(_ lhs: PKStrokePoint, _ rhs: PKStrokePoint) -> Bool {
        if #available(iOS 27.0, *) {
            return lhs.threshold == rhs.threshold && lhs.lateralJitter == rhs.lateralJitter
        }
        if #available(iOS 26.0, *) {
            return lhs.threshold == rhs.threshold
        }
        return true
    }

    private static func equalMask(_ lhs: UIBezierPath?, _ rhs: UIBezierPath?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?):
            return a.usesEvenOddFillRule == b.usesEvenOddFillRule &&
                a.cgPath == b.cgPath
        default: return false
        }
    }

    private static func equalColor(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        return lhs.resolvedColor(with: light).cgColor == rhs.resolvedColor(with: light).cgColor &&
            lhs.resolvedColor(with: dark).cgColor == rhs.resolvedColor(with: dark).cgColor
    }
}
