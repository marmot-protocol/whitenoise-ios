import CoreGraphics
import Foundation

nonisolated struct MessageLinkHitRegion: Equatable {
    let target: MessageLinkTarget
    let rect: CGRect

    static func regions(from runs: [(url: URL?, rect: CGRect)]) -> [MessageLinkHitRegion] {
        var regions: [MessageLinkHitRegion] = []
        for run in runs {
            guard let url = run.url,
                  let target = MessageLinkTarget(url: url),
                  !run.rect.isEmpty
            else { continue }
            if let last = regions.last,
               last.target == target,
               abs(last.rect.midY - run.rect.midY) < 1,
               abs(last.rect.maxX - run.rect.minX) < 1 {
                regions[regions.count - 1] = MessageLinkHitRegion(target: target, rect: last.rect.union(run.rect))
            } else {
                regions.append(MessageLinkHitRegion(target: target, rect: run.rect))
            }
        }
        return regions
    }
}
