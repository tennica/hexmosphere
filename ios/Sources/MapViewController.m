// SPDX-License-Identifier: Apache-2.0
// The whole app: read photo locations from the Photos library (with permission),
// bin them into H3 cells at solstone's three sizes, and shade them on a map.

#import "MapViewController.h"
#import <MapKit/MapKit.h>
#import <Photos/Photos.h>
#include "h3api.h"

static const int kLevels = 6;
static const int kResolutions[] = {8, 9, 10};

/// One photo's place and day.
@interface HXSample : NSObject
@property (nonatomic) CLLocationCoordinate2D coordinate;
@property (nonatomic) double accuracy;   // metres; 0 when unknown
@property (nonatomic, copy) NSString *day; // yyyy-MM-dd, local time
@property (nonatomic, strong) NSDate *date;
@end
@implementation HXSample
@end

/// What fell into one cell.
@interface HXCell : NSObject
@property (nonatomic) H3Index index;
@property (nonatomic) NSInteger photos;
@property (nonatomic, strong) NSMutableSet<NSString *> *days;
@property (nonatomic, strong) NSDate *first;
@property (nonatomic, strong) NSDate *last;
@end
@implementation HXCell
@end

@interface MapViewController () <MKMapViewDelegate>
@property (nonatomic, strong) MKMapView *map;
@property (nonatomic, strong) UISegmentedControl *sizeControl;
@property (nonatomic, strong) UISegmentedControl *shadeControl;
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, strong) UILabel *detail;
@property (nonatomic, strong) NSArray<HXSample *> *samples;
@property (nonatomic, strong) NSDictionary<NSNumber *, HXCell *> *cells;
@property (nonatomic) NSInteger total;
@property (nonatomic) NSInteger withoutLocation;
@property (nonatomic) NSInteger tooCoarse;
@end

@implementation MapViewController

static double edgeMetres(int res) {
    double out = 0;
    getHexagonEdgeLengthAvgM(res, &out);
    return out;
}

static NSString *sizeLabel(int res) {
    // Across between flat sides (edge x sqrt 3), as in solstone's labels.
    long across = lround(edgeMetres(res) * sqrt(3.0) / 10.0) * 10;
    return [NSString stringWithFormat:@"about %ld m", across];
}

- (int)resolution {
    return kResolutions[self.sizeControl.selectedSegmentIndex];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];

    self.map = [[MKMapView alloc] init];
    self.map.delegate = self;
    self.map.translatesAutoresizingMaskIntoConstraints = NO;
    [self.map addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];

    self.sizeControl = [[UISegmentedControl alloc] initWithItems:@[sizeLabel(8), sizeLabel(9), sizeLabel(10)]];
    self.sizeControl.selectedSegmentIndex = 1;
    [self.sizeControl addTarget:self action:@selector(redraw) forControlEvents:UIControlEventValueChanged];

    self.shadeControl = [[UISegmentedControl alloc] initWithItems:@[@"days with a photo", @"photos"]];
    self.shadeControl.selectedSegmentIndex = 0;
    [self.shadeControl addTarget:self action:@selector(reshade) forControlEvents:UIControlEventValueChanged];

    UIButton *fit = [UIButton buttonWithType:UIButtonTypeSystem];
    [fit setTitle:@"Fit all" forState:UIControlStateNormal];
    [fit addTarget:self action:@selector(fitAll) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[self.sizeControl, self.shadeControl, fit]];
    bar.spacing = 12;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    self.summary = [[UILabel alloc] init];
    self.summary.numberOfLines = 0;
    self.summary.font = [UIFont systemFontOfSize:13];
    self.summary.textColor = [UIColor darkGrayColor];
    self.summary.text = @"Asking for Photos access…";
    self.summary.translatesAutoresizingMaskIntoConstraints = NO;

    self.detail = [[UILabel alloc] init];
    self.detail.numberOfLines = 0;
    self.detail.font = [UIFont systemFontOfSize:14];
    self.detail.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9];
    self.detail.hidden = YES;
    self.detail.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.map];
    [self.view addSubview:bar];
    [self.view addSubview:self.summary];
    [self.view addSubview:self.detail];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [bar.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.map.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [self.map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.summary.topAnchor constraintEqualToAnchor:self.map.bottomAnchor constant:8],
        [self.summary.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.summary.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.summary.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [self.detail.leadingAnchor constraintEqualToAnchor:self.map.leadingAnchor constant:12],
        [self.detail.bottomAnchor constraintEqualToAnchor:self.map.bottomAnchor constant:-12],
    ]];

    [self loadPhotos];
}

#pragma mark - Photos

- (void)loadPhotos {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.summary.text = @"Photos access wasn't granted. Allow it in Settings → Privacy → Photos → Hexmosphere.";
            });
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDateFormatter *dayFormat = [[NSDateFormatter alloc] init];
            dayFormat.dateFormat = @"yyyy-MM-dd";
            NSMutableArray<HXSample *> *found = [NSMutableArray array];
            __block NSInteger missing = 0;
            PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithOptions:nil];
            [assets enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger i, BOOL *stop) {
                CLLocation *location = asset.location;
                if (!location || !asset.creationDate || !CLLocationCoordinate2DIsValid(location.coordinate) ||
                    (location.coordinate.latitude == 0 && location.coordinate.longitude == 0)) {
                    missing++;
                    return;
                }
                HXSample *sample = [[HXSample alloc] init];
                sample.coordinate = location.coordinate;
                sample.accuracy = location.horizontalAccuracy > 0 ? location.horizontalAccuracy : 0;
                sample.date = asset.creationDate;
                sample.day = [dayFormat stringFromDate:asset.creationDate];
                [found addObject:sample];
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.total = assets.count;
                self.withoutLocation = missing;
                self.samples = found;
                [self redraw];
                [self fitAll];
            });
        });
    }];
}

#pragma mark - Cells

- (void)redraw {
    int res = [self resolution];
    double edge = edgeMetres(res);
    NSMutableDictionary<NSNumber *, HXCell *> *cells = [NSMutableDictionary dictionary];
    NSInteger coarse = 0;
    for (HXSample *sample in self.samples) {
        if (sample.accuracy > edge) { coarse++; continue; }
        LatLng point = {degsToRads(sample.coordinate.latitude), degsToRads(sample.coordinate.longitude)};
        H3Index index = 0;
        if (latLngToCell(&point, res, &index) != E_SUCCESS) continue;
        NSNumber *key = @(index);
        HXCell *cell = cells[key];
        if (!cell) {
            cell = [[HXCell alloc] init];
            cell.index = index;
            cell.days = [NSMutableSet set];
            cell.first = sample.date;
            cell.last = sample.date;
            cells[key] = cell;
        }
        cell.photos++;
        [cell.days addObject:sample.day];
        if ([sample.date compare:cell.first] == NSOrderedAscending) cell.first = sample.date;
        if ([sample.date compare:cell.last] == NSOrderedDescending) cell.last = sample.date;
    }
    self.cells = cells;
    self.tooCoarse = coarse;
    self.detail.hidden = YES;
    [self reshade];
}

- (NSInteger)valueOf:(HXCell *)cell {
    return self.shadeControl.selectedSegmentIndex == 0 ? (NSInteger)cell.days.count : cell.photos;
}

- (void)reshade {
    [self.map removeOverlays:self.map.overlays];
    NSInteger top = 0;
    for (HXCell *cell in self.cells.allValues) top = MAX(top, [self valueOf:cell]);
    NSMutableArray<MKPolygon *> *polygons = [NSMutableArray array];
    for (HXCell *cell in self.cells.allValues) {
        CellBoundary boundary;
        if (cellToBoundary(cell.index, &boundary) != E_SUCCESS || boundary.numVerts < 3) continue;
        CLLocationCoordinate2D corners[MAX_CELL_BNDRY_VERTS];
        for (int i = 0; i < boundary.numVerts; i++) {
            corners[i] = CLLocationCoordinate2DMake(radsToDegs(boundary.verts[i].lat), radsToDegs(boundary.verts[i].lng));
        }
        MKPolygon *polygon = [MKPolygon polygonWithCoordinates:corners count:boundary.numVerts];
        // Log scale, so a few very busy cells don't wash out the rest.
        double share = top > 0 ? log((double)[self valueOf:cell] + 1) / log((double)top + 1) : 0;
        polygon.title = [NSString stringWithFormat:@"%d", MIN(kLevels - 1, (int)(share * kLevels))];
        [polygons addObject:polygon];
    }
    [self.map addOverlays:polygons level:MKOverlayLevelAboveRoads];
    [self updateSummary];
}

- (void)updateSummary {
    if (!self.samples) return;
    int res = [self resolution];
    NSMutableString *text = [NSMutableString stringWithFormat:@"%ld photos and videos · %lu with a location · %lu hexagons at %@ (res %d)",
                             (long)self.total, (unsigned long)self.samples.count, (unsigned long)self.cells.count, sizeLabel(res), res];
    if (self.tooCoarse > 0) {
        [text appendFormat:@" · %ld left out: position not known well enough for this size", (long)self.tooCoarse];
    }
    [text appendString:@". Tap a hexagon for details."];
    self.summary.text = text;
}

- (void)fitAll {
    MKMapRect rect = MKMapRectNull;
    for (id<MKOverlay> overlay in self.map.overlays) rect = MKMapRectUnion(rect, overlay.boundingMapRect);
    if (!MKMapRectIsNull(rect)) {
        [self.map setVisibleMapRect:rect edgePadding:UIEdgeInsetsMake(40, 40, 40, 40) animated:YES];
    }
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    CLLocationCoordinate2D where = [self.map convertPoint:[tap locationInView:self.map] toCoordinateFromView:self.map];
    LatLng point = {degsToRads(where.latitude), degsToRads(where.longitude)};
    H3Index index = 0;
    if (latLngToCell(&point, [self resolution], &index) != E_SUCCESS) return;
    HXCell *cell = self.cells[@(index)];
    if (!cell) { self.detail.hidden = YES; return; }
    NSDateFormatter *format = [[NSDateFormatter alloc] init];
    format.dateStyle = NSDateFormatterMediumStyle;
    self.detail.text = [NSString stringWithFormat:@"  %llx  \n  %lu days · %ld photos  \n  %@ – %@  ",
                        (unsigned long long)cell.index, (unsigned long)cell.days.count, (long)cell.photos,
                        [format stringFromDate:cell.first], [format stringFromDate:cell.last]];
    self.detail.hidden = NO;
}

#pragma mark - MKMapViewDelegate

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    MKPolygonRenderer *renderer = [[MKPolygonRenderer alloc] initWithPolygon:(MKPolygon *)overlay];
    int level = [((MKPolygon *)overlay).title intValue];
    CGFloat alpha = 0.15 + 0.7 * (level + 1) / (CGFloat)kLevels;
    renderer.fillColor = [[UIColor orangeColor] colorWithAlphaComponent:alpha];
    renderer.strokeColor = [[UIColor orangeColor] colorWithAlphaComponent:0.9];
    renderer.lineWidth = 0.8;
    return renderer;
}

@end
