# Hexmosphere

A Mac and iPad app that draws where your photos and videos were taken as [H3](https://h3geo.org) hexagons, shaded by how many photos fall in each.

**Whole Library…** reads the location, date and accuracy of every photo and video from the Photos library's own metadata. No image is opened or downloaded, so even a large library with originals in iCloud takes seconds. It needs Photos access, either Full or Limited to a chosen set, and never changes the library. Everything stays on the device.

A new take on the 2015–2018 [SCUPPERfoundation/hexmosphere](https://github.com/SCUPPERfoundation/hexmosphere), which used DGGRID and a MapKit demo client.

## Cell sizes

Odd H3 resolutions only, so each choice is about 7× finer across (49× in area) than the one before:

| H3 resolution | Across (flat to flat) | Scale |
| --- | --- | --- |
| 7 | about 2.4 km | town |
| 9 | about 350 m | neighbourhood; the default |
| 11 | about 50 m | building |

The sizes come out of a hexagon map prototype for [solstone](https://github.com/solpbc/solstone-journal/issues/397). In those tests, resolution 10 with a one-ring lookup matched a 50 m place rule, 11 was borderline, and 12 broke down.

A photo whose reported horizontal accuracy is coarser than the cell's edge is left out at that size and counted in the summary, so it can't land in a cell more or less at random. At resolution 11 that cut-off is about 29 m. Shading uses a log scale, so a few very busy cells don't wash out the rest.

## Build

Needs Xcode (macOS 15 / iPadOS 17 or later as targets), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for the default h3o backend, a [rustup](https://rustup.rs) toolchain with the iOS target.

```bash
# 1. The h3o library (always needed; both backends are built in)
rustup target add aarch64-apple-ios
Packages/h3o-ffi/build-xcframework.sh

# 2. The Xcode project
xcodegen generate

# 3. The Mac app (signed to run locally)
xcodebuild -project Hexmosphere.xcodeproj -scheme Hexmosphere -derivedDataPath build build
open build/Build/Products/Debug/Hexmosphere.app

# 4. The iPad app (needs your Apple team ID, Developer Mode on the iPad, and its UDID)
xcodebuild -project Hexmosphere.xcodeproj -scheme HexmosphereiPad -derivedDataPath build \
  -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<team ID> build
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/HexmosphereiPad.app
```

With a free Apple ID ("Personal Team"), an installed iPad build stops launching after about 7 days until it's rebuilt and reinstalled.

Per-photo picking (the Photos picker, or files from a folder) is in `MediaLocations.swift` but not in the interface at the moment. When it was, it needed no Photos permission: the Photos picker runs outside the app and hands over only the chosen items. Locations come from each file's own metadata: EXIF GPS for images, ISO 6709 for videos. Items without a location are counted in the summary.

If the originals live only in iCloud ("Optimize Storage"), Photos has to download each one first, and that can be slow. In that case, exporting with location and using **Open Files…** works too.

## Base map

By default the map shows **no Apple map content and fetches no tiles**. Instead it draws a bundled offline base map (about 5 MB) on a plain background:

- **Natural Earth** (public domain): coastlines, country borders, state and province lines, lakes, and about 7,300 world cities
- **OpenStreetMap place names** (ODbL, © OpenStreetMap contributors): cities, towns, suburbs and villages for chosen regions. Colorado is included. Smaller places are labelled as you zoom in.

The **Apple map** toggle switches to Apple's full street map, with realistic elevation. That fetches tiles from Apple for whatever area is on screen, so Apple can infer which places you're looking at.

### More detail: caching larger Natural Earth sets

The repository carries only the small set above. To build with more, cache a whole Natural Earth scale first:

```bash
scripts/fetch-basemap.sh naturalearth 50m    # all 45 layers, about 57 MB
scripts/fetch-basemap.sh naturalearth 10m    # all 129 layers, about 1 GB
scripts/fetch-basemap.sh naturalearth 110m   # all 32 layers, about 19 MB
```

The layers download once into `~/Library/Caches/hexmosphere/naturalearth/<version>/<scale>`. Set `HEXMOSPHERE_CACHE` to put the cache somewhere else. They're then cloned into `Basemap/naturalearth-extra/`, which is gitignored; on APFS that clone costs no extra space. The next build bundles whatever is there.

For each layer, the app uses the finest scale it finds, 10m before 50m before 110m. It draws the layers it has a style for, from bottom to top:

- glaciers and ice shelves
- dry lake beds
- urban areas
- lakes
- rivers
- tropics and polar circles
- coastlines
- state lines
- maritime and disputed borders
- land borders

Other cached layers, such as country polygons, graticules and region labels, are left out. So is the ocean: it's one world-sized polygon of about 61,000 points at 1:50m, and the coastline already shows where land ends. Each drawn layer is split into regional chunks on an 8×8 grid, so MapKit only draws the shapes near each tile. With the 50m set the app is about 60 MB. The base map loads in the background, so the window doesn't wait for it.

### More places

To add OpenStreetMap places for another region (one Overpass API query, with retries if the public server is busy):

```bash
scripts/fetch-basemap.sh places <name> <south> <west> <north> <east>
# e.g. scripts/fetch-basemap.sh places newmexico 31.3 -109.1 37.0 -103.0
```

Running the script with no arguments re-downloads the committed set: the Natural Earth layers above and the Colorado places.

## H3 backend (switch in the app)

Both H3 implementations are built in, and the **h3o / H3 C** switch in the toolbar picks one:

| Choice | Library |
| --- | --- |
| `h3o` (default) | [h3o](https://github.com/HydroniumLabs/h3o) 0.8.0, Rust, through `Packages/h3o-ffi` |
| `H3 C` | [Uber's H3](https://github.com/uber/h3) C library 4.1.0, `Packages/CH3` |

The two give identical cells and outlines: a comparison on 100,000 random points at resolutions 7, 9 and 11 found no differing cells, and vertex differences below 10⁻¹² degrees.

Their average edge lengths differ, though. H3 C 4.1.0's are about 13% smaller (174.4 m against 200.8 m at resolution 9). So switching relabels the sizes (about 2.4 km / 350 m / 50 m with h3o, about 2.1 km / 300 m / 40 m with H3 C) and moves the accuracy cut-off; the hexagons themselves stay put. The summary line names the library in use.

Building needs the Rust part either way: `Packages/h3o-ffi/build-xcframework.sh`, with a rustup toolchain that has `aarch64-apple-ios`.

## Layout

- `Sources/Hexmosphere`: the app, shared by Mac and iPad (SwiftUI):
  - `H3Grid.swift`: H3 wrappers for both backends, cell sizes, binning
  - `MediaLocations.swift`: reads location and date from chosen photos and files
  - `HexMapView.swift`: MapKit, with one multipolygon per shade level
  - `ContentView.swift`: controls and summary
- `Packages/h3o-ffi`: a small Rust crate exposing three h3o functions to C, built into `CH3O.xcframework` (Mac and iOS)
- `Packages/CH3`: Uber's H3 v4.1.0 C library, vendored unchanged as a SwiftPM C target (Apache-2.0; `LICENSE-h3`). `include/h3api.h` is generated from `h3api.h.in` with the version filled in. Source: the v4.1.0 release tarball, sha256 `ec99f1f5974846bde64f4513cf8d2ea1b8d172d2218ab41803bf6a63532272bc`.
- `ios/`: an experimental Objective-C build for iOS 12 devices (for example, the iPad mini 3), compiled with `clang` because current Xcode won't target iOS 12. It reads the whole Photos library with permission, since iOS 12 has no limited picker. It's unsigned and not maintained.
- `Basemap/`: the offline base map data, fetched by `scripts/fetch-basemap.sh` and drawn by `Sources/Hexmosphere/Basemap.swift`:
  - `naturalearth/`: public domain
  - `naturalearth-extra/`: local caches only, gitignored
  - `osm/`: ODbL, with its own `LICENSE.md`
- `project.yml`: the XcodeGen project (targets `Hexmosphere` for macOS and `HexmosphereiPad` for iPadOS)

## Ideas for later

- Workout routes from HealthKit (iPad), and Core Location visit monitoring going forward
- A time filter by year or month
- A RealityKit globe view
- Tapping a cell to show its photos

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
