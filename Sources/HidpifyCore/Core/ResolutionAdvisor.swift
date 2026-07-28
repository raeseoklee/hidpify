import Foundation

/// One "looks-like WxH" suggestion for a HiDPI target.
public struct ResolutionCandidate {
    public let width: Int
    public let height: Int
    public let label: String
    public let isDensityMatch: Bool

    public init(width: Int, height: Int, label: String, isDensityMatch: Bool) {
        self.width = width
        self.height = height
        self.label = label
        self.isDensityMatch = isDensityMatch
    }
}

/// Suggests "looks-like" resolutions for a HiDPI target, keeping its current
/// aspect ratio. See DESIGN.md §8.3 ("밀도 일치 제안").
public enum ResolutionAdvisor {
    /// Builds a ladder of aspect-ratio-preserving candidates for `target`, plus
    /// (when useful) candidates that match the logical PPI of displays in `others`.
    ///
    /// - Aspect ratio: the reduced ratio (gcd) of `target`'s current logical resolution.
    /// - Range: native pixels ÷ 2 (pure 2x) through native pixels × 0.8, stepped in
    ///   integer multiples of the aspect ratio, yielding roughly 5–9 candidates.
    /// - For each display in `others` whose `logicalPPI` differs from `target`'s by
    ///   3% or more, adds a density-match candidate: the aspect-ratio multiple whose
    ///   diagonal logical pixel count is closest to `other.logicalPPI × target`'s
    ///   diagonal size in inches, labeled "W × H — matches <name> density".
    /// - Duplicates (by width×height) are removed, preferring the density-match
    ///   label. Results are sorted largest-first.
    public static func candidates(for target: DisplayInfo, others: [DisplayInfo]) -> [ResolutionCandidate] {
        guard target.logicalWidth > 0, target.logicalHeight > 0 else { return [] }

        let divisor = gcd(target.logicalWidth, target.logicalHeight)
        let ratioW = target.logicalWidth / divisor
        let ratioH = target.logicalHeight / divisor
        guard ratioW > 0, ratioH > 0 else { return [] }
        let ratioDiagonal = (Double(ratioW * ratioW + ratioH * ratioH)).squareRoot()

        let nativeWidth = target.pixelWidth > 0 ? target.pixelWidth : target.logicalWidth
        let minWidth = Double(nativeWidth) / 2.0
        let maxWidth = Double(nativeWidth) * 0.8

        var byKey: [String: ResolutionCandidate] = [:]

        func add(width: Int, height: Int, label: String, isDensityMatch: Bool) {
            guard width > 0, height > 0 else { return }
            let key = "\(width)x\(height)"
            if let existing = byKey[key], existing.isDensityMatch && !isDensityMatch {
                // Keep the more informative density-match label already present.
                return
            }
            byKey[key] = ResolutionCandidate(
                width: width,
                height: height,
                label: label,
                isDensityMatch: isDensityMatch
            )
        }

        // Aspect-ratio ladder: integer multiples of (ratioW, ratioH) spanning
        // [nativeWidth/2, nativeWidth*0.8], aiming for 5–9 evenly spaced steps.
        if minWidth <= maxWidth {
            let kMin = max(1, Int(ceil(minWidth / Double(ratioW))))
            let kMax = max(kMin, Int(floor(maxWidth / Double(ratioW))))
            let desiredCount = 7
            let span = kMax - kMin
            let step = max(1, span / (desiredCount - 1))

            var k = kMin
            while k <= kMax {
                let width = k * ratioW
                let height = k * ratioH
                add(width: width, height: height, label: "\(width) × \(height)", isDensityMatch: false)
                k += step
            }
            if kMax > kMin {
                let width = kMax * ratioW
                let height = kMax * ratioH
                add(width: width, height: height, label: "\(width) × \(height)", isDensityMatch: false)
            }
        }

        // Density-match candidates: snap the diagonal logical pixel count that
        // would reproduce `other`'s PPI on `target`'s physical panel size.
        let targetPPI = target.logicalPPI
        if targetPPI > 0 {
            let diagonalInches = (target.physicalWidthMM * target.physicalWidthMM
                + target.physicalHeightMM * target.physicalHeightMM).squareRoot() / 25.4
            if diagonalInches > 0 {
                for other in others {
                    let otherPPI = other.logicalPPI
                    guard otherPPI > 0 else { continue }
                    guard abs(otherPPI - targetPPI) / targetPPI >= 0.03 else { continue }

                    let desiredDiagonalPixels = otherPPI * diagonalInches
                    let k = max(1, Int((desiredDiagonalPixels / ratioDiagonal).rounded()))
                    let width = k * ratioW
                    let height = k * ratioH
                    add(
                        width: width,
                        height: height,
                        label: "\(width) × \(height) — matches \(other.name) density",
                        isDensityMatch: true
                    )
                }
            }
        }

        return byKey.values.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a)
        var b = abs(b)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }
}
