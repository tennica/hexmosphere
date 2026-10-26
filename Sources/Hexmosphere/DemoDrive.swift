// SPDX-License-Identifier: Apache-2.0
// Demo Drive routes for Where I Am. Besides a sketched loop round San Francisco, they're
// bundled in Basemap/routes, made from the fetched OpenStreetMap streets (ODbL) by
// scripts/demo-route.py: real roads, each driven at a real-life speed times a speed-up.

import CoreLocation
import Foundation

struct DemoRoute: Identifiable {
    let id: String
    let title: String
    let note: String
    /// Metres a second in real life, and how many times faster the demo runs.
    let speed: Double
    let times: Double
    /// A loop goes round; any other route turns back at its end.
    let loops: Bool
    private let points: [CLLocation]
    private let legs: [Double]
    let length: Double

    init(id: String, title: String, note: String, speed: Double, times: Double, loops: Bool, points: [CLLocation]) {
        self.id = id
        self.title = title
        self.note = note
        self.speed = speed
        self.times = times
        self.loops = loops
        self.points = loops ? points + [points[0]] : points
        legs = zip(self.points, self.points.dropFirst()).map { $0.distance(from: $1) }
        length = legs.reduce(0, +)
    }

    /// Where the drive is after this many metres: round a loop, or there and back.
    func position(after metres: Double) -> CLLocation {
        var left = metres.truncatingRemainder(dividingBy: loops ? length : 2 * length)
        if left > length { left = 2 * length - left }
        var leg = 0
        while leg < legs.count - 1, left > legs[leg] {
            left -= legs[leg]
            leg += 1
        }
        let from = points[leg].coordinate, to = points[leg + 1].coordinate
        let share = legs[leg] > 0 ? min(1, left / legs[leg]) : 0
        let here = CLLocationCoordinate2D(latitude: from.latitude + (to.latitude - from.latitude) * share,
                                          longitude: from.longitude + (to.longitude - from.longitude) * share)
        return CLLocation(coordinate: here, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: .now)
    }

    /// Fort Mason, the Marina, the Presidio's edge, Golden Gate Park, the Castro, the
    /// Mission, SoMa, the Ferry Building and Fisherman's Wharf: landmarks picked by hand,
    /// joined by straight lines that cut through blocks.
    static let sketch = DemoRoute(
        id: "sketch", title: "San Francisco loop (sketched)",
        note: "Straight lines between landmarks, not along streets", speed: 15, times: 1, loops: true,
        points: [
            (37.8048, -122.4271), (37.8030, -122.4370), (37.7840, -122.4470), (37.7694, -122.4862),
            (37.7600, -122.4350), (37.7599, -122.4148), (37.7790, -122.3900), (37.7955, -122.3937),
            (37.8080, -122.4177),
        ].map { CLLocation(latitude: $0.0, longitude: $0.1) })

    /// The sketch, then every bundled route by title.
    static let all: [DemoRoute] = {
        guard let dir = Bundle.main.url(forResource: "Basemap", withExtension: nil)?.appendingPathComponent("routes"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return [sketch]
        }
        let routes = files.filter { $0.lastPathComponent.hasPrefix("route-") && $0.pathExtension == "json" }.compactMap { url -> DemoRoute? in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String, let speed = json["speed"] as? Double,
                  let times = json["times"] as? Double, let pairs = json["points"] as? [[Double]], pairs.count >= 2 else { return nil }
            return DemoRoute(id: url.deletingPathExtension().lastPathComponent, title: title,
                             note: json["note"] as? String ?? "", speed: speed, times: times, loops: false,
                             points: pairs.map { CLLocation(latitude: $0[1], longitude: $0[0]) })
        }
        return [sketch] + routes.sorted { $0.title < $1.title }
    }()
}
