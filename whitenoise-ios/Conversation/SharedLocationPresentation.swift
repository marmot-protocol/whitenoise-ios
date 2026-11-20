import Foundation
import MapKit
import SwiftUI
import UIKit

nonisolated struct SharedLocation: Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let url: URL

    static func parse(_ text: String) -> Self? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 2_048,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.port == nil
        else { return nil }

        let coordinateValue: String?
        switch host {
        case "www.google.com":
            guard components.path == "/maps/search/" || components.path == "/maps/search",
                  uniqueQueryValue(named: "api", in: components) == "1"
            else { return nil }
            coordinateValue = uniqueQueryValue(named: "query", in: components)

        case "maps.apple.com":
            guard components.path.isEmpty || components.path == "/" else { return nil }
            coordinateValue = uniqueQueryValue(named: "ll", in: components)

        default:
            return nil
        }

        guard let coordinateValue,
              let coordinate = parseCoordinate(coordinateValue),
              let url = components.url
        else { return nil }

        return Self(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            url: url
        )
    }

    private static func uniqueQueryValue(
        named name: String,
        in components: URLComponents
    ) -> String? {
        let matches = components.queryItems?.filter { $0.name == name } ?? []
        guard matches.count == 1, let value = matches[0].value else { return nil }
        return value
    }

    private static func parseCoordinate(
        _ value: String
    ) -> (latitude: Double, longitude: Double)? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              latitude.isFinite,
              longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude)
        else { return nil }
        return (latitude, longitude)
    }
}

nonisolated enum SharedLocationText {
    static func value(latitude: Double, longitude: Double) -> String {
        let latitude = coordinateString(latitude)
        let longitude = coordinateString(longitude)
        return "https://www.google.com/maps/search/?api=1&query=\(latitude)%2C\(longitude)"
    }

    static func location(from text: String) -> SharedLocation? {
        SharedLocation.parse(text)
    }

    private static func coordinateString(_ value: Double) -> String {
        String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }
}

struct SharedLocationMapPreview: View {
    static let height: CGFloat = 140

    let location: SharedLocation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    #if DEBUG
    @Environment(\.isChatFixture) private var isChatFixture
    #endif
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        GeometryReader { geometry in
            let scale = max(1, displayScale)
            let width = max(1, ceil(geometry.size.width * scale) / scale)
            let request = SharedLocationSnapshotRequest(
                latitude: location.latitude,
                longitude: location.longitude,
                width: width,
                height: Self.height,
                scale: scale,
                dark: colorScheme == .dark
            )

            ZStack {
                Color(.secondarySystemBackground)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if didFail {
                    Image(systemName: "map")
                        .font(.title)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }

                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .white)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: request) {
                image = nil
                #if DEBUG
                if isChatFixture { didFail = true; return }
                #endif
                didFail = false
                do {
                    image = try await SharedLocationSnapshotStore.image(for: request)
                } catch is CancellationError {
                    return
                } catch {
                    didFail = true
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
    }
}

private struct SharedLocationSnapshotRequest: Hashable {
    let latitude: Double
    let longitude: Double
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    let dark: Bool

    var cacheKey: NSString {
        let latitude = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            latitude
        )
        let longitude = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            longitude
        )
        let size = String(
            format: "%.2fx%.2f@%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            width,
            height,
            scale
        )
        return "\(latitude),\(longitude):\(size):\(dark ? "dark" : "light")" as NSString
    }
}

@MainActor
private enum SharedLocationSnapshotStore {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private static var inFlight: [NSString: Task<UIImage, Error>] = [:]

    static func image(for request: SharedLocationSnapshotRequest) async throws -> UIImage {
        if let cached = cache.object(forKey: request.cacheKey) {
            return cached
        }
        if let existing = inFlight[request.cacheKey] {
            return try await existing.value
        }

        let task = Task { @MainActor in
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: request.latitude,
                    longitude: request.longitude
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: 0.012,
                    longitudeDelta: 0.018
                )
            )
            options.size = CGSize(width: request.width, height: request.height)
            options.scale = max(1, request.scale)
            options.mapType = .standard
            options.pointOfInterestFilter = .excludingAll
            options.traitCollection = UITraitCollection(
                userInterfaceStyle: request.dark ? .dark : .light
            )
            return try await MKMapSnapshotter(options: options).start().image
        }
        inFlight[request.cacheKey] = task
        defer { inFlight[request.cacheKey] = nil }

        let image = try await task.value
        let pixelCost = max(
            1,
            Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        )
        cache.setObject(image, forKey: request.cacheKey, cost: pixelCost)
        return image
    }
}
