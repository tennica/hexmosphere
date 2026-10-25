// SPDX-License-Identifier: Apache-2.0
// Where you are, as one hexagon: Core Location while the app is in use, turned into the H3
// cell at the chosen size. The last fix is held in memory while it's on, to place you again
// when the cell size changes, and forgotten when it's turned off; nothing is written to
// disk, exported or sent anywhere.

import CoreLocation
import Observation

@Observable final class HereTracker: NSObject, CLLocationManagerDelegate {
    /// The hexagon you're in, at the size last asked for; nil when off, not yet known or refused.
    private(set) var cell: CellID?
    /// Why there's no hexagon to show, for the summary line.
    private(set) var note: String?
    private(set) var on = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var size = CellSize.r7
    @ObservationIgnored private var backend = H3Backend.h3o
    /// The last fix, held only to re-place it when the cell size changes.
    @ObservationIgnored private var last: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        // A city-block fix is enough for the smallest cells (about 50 m across), and kinder to the battery.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
    }

    /// Turns it on: asks for location while the app is in use, the first time.
    func start(size: CellSize, backend: H3Backend) {
        on = true
        self.size = size
        self.backend = backend
        note = "Finding where you are…"
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: locationManagerDidChangeAuthorization(manager)
        }
    }

    func stop() {
        on = false
        manager.stopUpdatingLocation()
        cell = nil
        last = nil
        note = nil
    }

    /// The cell size or H3 backend changed: the same position, a different hexagon.
    func use(size: CellSize, backend: H3Backend) {
        self.size = size
        self.backend = backend
        if let last { place(last) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard on else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            break
        case .denied, .restricted:
            cell = nil
            note = "Location is off for Hexmosphere. Allow it in Settings, under Privacy & Security, Location Services."
        default:
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard on, let location = locations.last else { return }
        last = location
        place(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard on else { return }
        note = "Can't tell where you are just now."
    }

    /// Updates the hexagon only when it changes. As with photos, a position known less
    /// well than the cell is wide doesn't place you in one.
    private func place(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= size.edgeMetres(backend) else {
            cell = nil
            note = "Your position isn't known well enough for this cell size yet."
            return
        }
        note = nil
        let here = cellFor(location.coordinate, size: size, backend: backend)
        if here != cell { cell = here }
    }
}
