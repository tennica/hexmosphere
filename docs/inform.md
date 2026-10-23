# From hexagons to Inform rooms

*An idea, not a feature: nothing here is built yet.*

Hexmosphere finds the places your photos come from and indexes them as H3 hexagons. [Inform 7](https://ganelson.github.io/inform-website/) describes a story's world as rooms joined by exits. The two models turn out to fit closely, and most of the pieces a converter would need already exist in the app because of the [Tiled export](../README.md#exporting-to-tiled).

## Neighbours become exits

Inform connects rooms by compass direction: north, northeast, east, southeast, south, southwest, west, northwest, plus up and down. A hexagon has six neighbours, so it uses six of those eight directions.

Which six depends on how the hexagons sit. The Tiled export already turns H3's grid to within 15° of north up, choosing pointy-topped or flat-topped hexagons as it goes ([TiledLayout.swift](../Sources/Hexmosphere/TiledLayout.swift)). After that turn:

| Hexagon kind | Neighbours lie | Unused |
| --- | --- | --- |
| pointy-topped (rows staggered) | east, west, northeast, northwest, southeast, southwest | north, south |
| flat-topped (columns staggered) | north, south, northeast, northwest, southeast, southwest | east, west |

The exit should come from the neighbour's side of the hexagon, not from its measured bearing. Up to 15° of turn is left over, so a bearing can sit close to the line between two compass points; naming exits by grid side keeps them consistent across the whole map, and every exit has a matching way back.

## Sizes become regions

Inform 7 lets rooms belong to regions, and regions can sit inside larger regions. H3 nests the same way: every cell has a parent about 2.65 times larger across. The app's five cell sizes give a ready-made hierarchy:

| H3 resolution | Across | In the story |
| --- | --- | --- |
| 9 | about 350 m | a room |
| 7 | about 2.4 km | a neighbourhood region |
| 5 | about 17 km | a town or metro region |
| 3 | about 120 km | a wider region |

H3's parents only approximately cover their children, so a region's edge is a little ragged. A story won't notice.

## The Tiled export is halfway there

Each hexagon in an export is an object with its H3 index, centre, photo count, days and first and last dates, and a blank name for you to fill in Tiled. A converter would:

1. Read the `places` layer of `hexmosphere.tmj`.
2. Make a room for each hexagon that has a name, and leave unnamed hexagons out (or make them plain connecting rooms).
3. Join named neighbours with exits, by grid side as above.
4. Put each room in regions from its H3 parents.

For two named neighbours at resolution 9 in the same resolution-7 parent, the output could read:

```inform7
Riverside is a region.

The Corner Café is a room. "You have been here on 40 days since 2019."
The Corner Café is in Riverside.

The Old Mill Park is a room. The Old Mill Park is in Riverside.
The Old Mill Park is northeast of The Corner Café.
```

Inform makes the way back (southwest) by itself. The day count comes from the hexagon's own properties.

## Why Tiled in the middle

Tiled maps are plain files that many tools read, so the same named places could feed an Inform story, a game engine, or a WorkAdventure space without any of them depending on Hexmosphere. Naming places is the creative step, and Tiled is a good place to do it: the hexagons are laid out north up, with each one's numbers attached.

## Limits

- **Distance:** H3's local grid only places cells within a limited range of the export's centre, and not across one of H3's twelve pentagons. An export reports how many cells it left out.
- **Six directions, not eight:** a story that needs all eight compass points, or up and down, needs hand-made exits on top.
- **Privacy:** named places with visit counts say a lot about a person. The export already leaves out Photos library identifiers; a story built from it is as private as you keep it.
