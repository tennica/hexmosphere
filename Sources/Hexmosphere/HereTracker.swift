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
    /// True while the demo drive stands in for Core Location.
    private(set) var driving = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var size = CellSize.r7
    @ObservationIgnored private var backend = H3Backend.h3o
    /// The last fix, held only to re-place it when the cell size changes.
    @ObservationIgnored private var last: CLLocation?
    @ObservationIgnored private var driveTimer: Timer?

    override init() {
        super.init()
        manager.delegate = self
        // A city-block fix is enough for the smallest cells (about 50 m across), and kinder to the battery.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
    }

    /// Turns it on: asks for location while the app is in use, the first time.
    func start(size: CellSize, backend: H3Backend) {
        stopDriving()
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
        stopDriving()
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
        guard on, !driving else { return }
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
        guard on, !driving, let location = locations.last else { return }
        last = location
        place(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard on, !driving else { return }
        note = "Can't tell where you are just now."
    }

    /// Turns it on with the demo drive in place of Core Location: a loop around San
    /// Francisco at city speed, one position a second, for trying Where I Am anywhere.
    func drive(size: CellSize, backend: H3Backend) {
        stop()
        on = true
        driving = true
        self.size = size
        self.backend = backend
        var travelled = 0.0
        let step = { [weak self] in
            guard let self else { return }
            let location = DemoDrive.position(after: travelled)
            travelled += DemoDrive.speed
            last = location
            place(location)
        }
        step()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in step() }
        // Common modes, so the drive keeps going while the map is being panned.
        RunLoop.main.add(timer, forMode: .common)
        driveTimer = timer
    }

    private func stopDriving() {
        driveTimer?.invalidate()
        driveTimer = nil
        driving = false
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

/// The demo drive: Fort Mason, the Marina, the Presidio's edge, Golden Gate Park, the
/// Castro, the Mission, SoMa, the Ferry Building and back, about 23 km in straight
/// lines between these points, so it cuts through blocks.
enum DemoDrive {
    static let speed = 15.0   // metres a second, about 54 km/h
    static let route = [
        (37.8048, -122.4271), (37.8030, -122.4370), (37.7840, -122.4470), (37.7694, -122.4862),
        (37.7600, -122.4350), (37.7599, -122.4148), (37.7790, -122.3900), (37.7955, -122.3937),
        (37.8080, -122.4177),
    ].map { CLLocation(latitude: $0.0, longitude: $0.1) }

    private static let legs: [Double] = route.indices.map { route[$0].distance(from: route[($0 + 1) % route.count]) }

    /// Where the drive is after this many metres, round the loop as often as needed.
    static func position(after metres: Double) -> CLLocation {
        var left = metres.truncatingRemainder(dividingBy: legs.reduce(0, +))
        var leg = 0
        while left > legs[leg] {
            left -= legs[leg]
            leg += 1
        }
        let from = route[leg].coordinate, to = route[(leg + 1) % route.count].coordinate
        let share = legs[leg] > 0 ? left / legs[leg] : 0
        let here = CLLocationCoordinate2D(latitude: from.latitude + (to.latitude - from.latitude) * share,
                                          longitude: from.longitude + (to.longitude - from.longitude) * share)
        return CLLocation(coordinate: here, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: .now)
    }
}
