// SPDX-License-Identifier: Apache-2.0
#import "AppDelegate.h"
#import "MapViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[MapViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
