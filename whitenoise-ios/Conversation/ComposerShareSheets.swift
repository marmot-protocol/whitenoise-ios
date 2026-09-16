import Contacts
import ContactsUI
import Combine
import CoreLocation
import MapKit
import SwiftUI

enum ContactCardExport {
    static func data(for contact: CNContact) throws -> Data {
        try CNContactVCardSerialization.data(with: [contact])
    }

    static func fileName(for contact: CNContact) -> String {
        let displayName = CNContactFormatter.string(from: contact, style: .fullName) ?? L10n.string("Contact")
        let sanitized = displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(sanitized.isEmpty ? "contact" : sanitized).vcf"
    }
}

struct ContactCardPicker: UIViewControllerRepresentable {
    let onPick: (CNContact) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactCardPicker

        init(parent: ContactCardPicker) {
            self.parent = parent
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            parent.onPick(contact)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}

struct LocationPickerView: View {
    let onSend: (CLLocationCoordinate2D) -> Void
    let onCancel: () -> Void

    @StateObject private var location = LocationPickerModel()

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $location.position) {
                    UserAnnotation()
                    if let coordinate = location.selectedCoordinate {
                        Marker(L10n.string("Selected location"), coordinate: coordinate)
                    }
                }
                .mapControls {
                    MapCompass()
                    MapUserLocationButton()
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    location.select(coordinate)
                }
                .safeAreaInset(edge: .bottom) {
                    locationFooter
                }
            }
            .navigationTitle(L10n.string("Send location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("Cancel"), action: onCancel)
                }
            }
        }
        .onAppear { location.start() }
    }

    private var locationFooter: some View {
        VStack(spacing: 10) {
            if let message = location.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.string("Tap the map to choose a location."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            WNButton(
                title: "Send this location",
                systemImage: "location.fill",
                size: .standard
            ) {
                guard let coordinate = location.selectedCoordinate else { return }
                onSend(coordinate)
            }
            .disabled(location.selectedCoordinate == nil)
        }
        .padding()
        .background(.regularMaterial)
    }
}

@MainActor
private final class LocationPickerModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var position: MapCameraPosition = .automatic
    @Published var selectedCoordinate: CLLocationCoordinate2D?
    @Published var statusMessage: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            statusMessage = L10n.string("Location access is unavailable. Tap the map to choose a place.")
        @unknown default:
            statusMessage = L10n.string("Tap the map to choose a location.")
        }
    }

    func select(_ coordinate: CLLocationCoordinate2D) {
        selectedCoordinate = coordinate
        position = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        statusMessage = nil
        select(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusMessage = L10n.string("Your current location could not be found. Tap the map to choose a place.")
    }
}
