# The Mentagon

*A design, partly built: the Tiled export of the Mentagon exists, and the planet is next. It joins two older ideas: the [h6](https://github.com/SCUPPERfoundation/h6/tree/prototype) design from 2021, a prototype engine for the game Federation 3 that was also called Hexmosphere, and the hexagons-to-Inform-rooms plan in [inform.md](inform.md).*

In h6, every new player starts in the Mentagon, a five-sided space with no real location. As players come to understand the world, they anchor themselves to one of the twelve pentagons H3 needs to cover a sphere, and together they claim hexagons, which split into finer cells once enough players make one their home.

Here the Mentagon becomes the first real world built from H3: a starter planet that new characters land on before they anchor.

## Built from an empty pentagon

H3 has twelve pentagons at every resolution, each centred on the same twelve points. Most sit over open ocean, but the coarse ones are huge: ten of the twelve resolution 0 pentagons contain some land, and two still do at resolution 3. From resolution 4 down, none do.

The Mentagon is base cell 72, the pentagon in the South Pacific whose whole resolution 0 cell holds no land:

| H3 resolution | Cells | Each about | In the story |
| --- | --- | --- | --- |
| 4 | 1 (a pentagon) | 897 km² | the Mentagon |
| 5 | 6 | 150 km² | regions |
| 6 | 41 | 22 km² | rooms |

The resolution 4 pentagon is about half the area of an average resolution 4 hexagon, and its 41 rooms cover the same 897 km². The nearest land is Ducie Island,[^ducie] about 1,600 km away, measured against [Natural Earth](https://www.naturalearthdata.com) 1:10m land and minor islands (public domain). The patch uses no basemap tiles and no place names.

[^ducie]: Ducie Island, an uninhabited atoll about 470 km east of Pitcairn, was first sighted in 1606 by Pedro Fernandes de Queirós, who called it Luna Puesta. Captain Edward Edwards of HMS *Pandora* came upon it again in March 1791 while hunting the *Bounty* mutineers (who, unknown to him, had settled on Pitcairn), and named it after Captain Francis Reynolds-Moreton, 3rd Baron Ducie, under whom he had served in HMS *Augusta*. It's said "DOO-see", which to some ears comes out close to "duchy": fitting for a lord's name on a far corner of a British Overseas Territory, the Pitcairn Islands. A lord's name on a speck of land alone in open sea would sit well in *One Piece*.

## Five sides at every level

A hexagon has seven children; a pentagon has six: a smaller pentagon at its centre and five hexagons around it. So the pentagon recurs at every level, and the centre room of the Mentagon has five exits, not six. [inform.md](inform.md) names exits by a hexagon's sides, so the pentagon's five are the same compass points as a hexagon's, with one missing.

A pentagon can't lie flat. On the Tiled map, with the pentagon room as origin (from any other room, H3's local grid can't place 16 of the 41), 95 of the 100 pairs of neighbouring rooms touch. The other five open along the pentagon's missing direction, a seam that widens outwards, and get no exit. Every room can still be reached. Exits across the seam, named some other way than by compass, are left for later.

Launching the app with `-export-mentagon <folder>` writes the Mentagon's Tiled map to that folder in the app's Documents (inside its container on the Mac): 41 rooms, each with its `region`, and `pentagon` on the centre room. inform-federation's converter turns it into a planet with exactly those 95 exits.

As in inform.md, regions follow H3's index hierarchy, not geometry: a parent's children only roughly cover it, which a story won't notice.

## Privacy

Real maps raise a real question: can anything in the world, or in a player's place in it, point back to a person? The Mentagon can't, since it's empty ocean. The risk is in anchoring, and in any later feature that uses real places.

### Sparse places are the risk

How identifying a map cell is depends on how many people live in it, not on its size. A city cell hides a person among thousands. A cell on a small island, or on a coast next to open ocean, can point to a handful of people. This idea is well established in privacy research. It's [k-anonymity](https://en.wikipedia.org/wiki/K-anonymity), and studies of location data show how little it takes to single someone out (Golle & Partridge, 2009; de Montjoye et al., "Unique in the Crowd", 2013). It's also why a map can't be used to decide that a place is "empty": a coastline dataset can miss an atoll.

### Rules for anchoring

Later, players anchor to one of the twelve pentagons. These rules come before any code:

1. **The anchor choice never reveals where the player is.** No "nearest to you" suggestion. Nothing is derived from IP address, time zone or locale. Anchors are chosen freely or at random.
2. **Any feature that uses real places has a minimum population per cell.** Cells are coarsened until each covers at least *k* people, using a public population grid (GHS-POP or WorldPop, both CC BY 4.0, with attribution). Sparse places get coarser cells automatically. *k* is still to be set.
3. **"Empty" is never decided by a land mask alone.** Cells are checked against a small-island source too.
4. **A player's anchor isn't stored next to anything that identifies them**, such as their IP address or account email.

## Thanks

Thanks to Rob Lanphier ([@robla](https://github.com/robla)), who years ago offered feedback on how ocean and land change the privacy picture. It's a well-known point in privacy work, and hearing it early is why these rules exist before the code does. Feedback is welcome: open an issue.

Thanks also to Eiichiro Oda (Oda-san) and *One Piece*, whose world of islands scattered across open sea has kept dvd thinking about this stuff for years.

---

Drafted with Claude; reviewed by dvd.
