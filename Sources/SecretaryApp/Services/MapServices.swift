import CoreLocation
import Foundation
import MapKit
import SecretaryCore

private func mapItem(_ c: Coordinate) -> MKMapItem {
    let coordinate = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    if #available(macOS 26, *) {
        return MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
    }
    return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
}

/// Traffic-aware ETA via MapKit (DEC-006, DEC-020).
struct MapKitTravelEstimator: TravelEstimating {
    func travelTime(from: Coordinate, to: Coordinate, mode: TransportMode, departure: Date) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = mapItem(from)
        request.destination = mapItem(to)
        request.departureDate = departure
        switch mode {
        case .driving: request.transportType = .automobile
        case .transit: request.transportType = .transit
        case .walking: request.transportType = .walking
        }
        let eta = try await MKDirections(request: request).calculateETA()
        return eta.expectedTravelTime
    }
}

/// Address and place search via MapKit (DEC-011, DEC-020).
struct MapKitGeocoder: Geocoding {
    func geocode(_ query: String, near: Coordinate?) async throws -> GeocodedAddress? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        guard let item = try await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate: CLLocationCoordinate2D
        var address: String?
        if #available(macOS 26, *) {
            coordinate = item.location.coordinate
            address = item.address?.fullAddress
        } else {
            coordinate = item.placemark.coordinate
            address = item.placemark.title
        }
        let parts = [item.name, address].compactMap { $0 }.filter { !$0.isEmpty }
        // Avoid "Name, Name, Street" when the address already starts with the name.
        let text = parts.count == 2 && parts[1].hasPrefix(parts[0]) ? parts[1] : parts.joined(separator: ", ")
        return GeocodedAddress(address: text.isEmpty ? query : text,
                               coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    func address(at coordinate: Coordinate) async throws -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let place = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [place.subThoroughfare, place.thoroughfare]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let parts = [street.isEmpty ? place.name : street, place.locality,
                     place.administrativeArea, place.postalCode, place.country]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Keeps the latest Mac location fix (DEC-014). Denied permission simply yields no fix, so home is used.
@MainActor
final class LocationService: NSObject, LocationProviding, CLLocationManagerDelegate {
    enum LookupError: LocalizedError {
        case permissionDenied, unavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Location access is off. Enable it in System Settings → Privacy & Security → Location Services, or enter an address manually."
            case .unavailable:
                return "The Mac could not get a current location. Try again or enter an address manually."
            }
        }
    }

    private let manager = CLLocationManager()
    private var fix: LocationFix?
    private var timer: Timer?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        if isAuthorized { manager.requestLocation() }
        // Keep the fix younger than 30 minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let self, self.isAuthorized { self.manager.requestLocation() }
            }
        }
    }

    func latestFix() async -> LocationFix? { fix }

    private var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// Wait for a fresh fix when the user asks to find the home address.
    func currentFix() async throws -> LocationFix {
        let requestedAt = Date()
        var requestedLocation = false
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        for _ in 0..<40 {
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                throw LookupError.permissionDenied
            }
            if isAuthorized && !requestedLocation {
                manager.requestLocation()
                requestedLocation = true
            }
            if let fix, fix.timestamp >= requestedAt.addingTimeInterval(-5) { return fix }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LookupError.unavailable
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let newFix = LocationFix(coordinate: Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude),
                                 timestamp: last.timestamp)
        Task { @MainActor in self.fix = newFix }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.isAuthorized { self.manager.requestLocation() }
        }
    }
}
