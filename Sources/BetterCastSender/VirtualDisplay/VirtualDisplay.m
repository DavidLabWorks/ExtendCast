// -*- Mode: ObjC; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4; fill-column: 100 -*-

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "CGVirtualDisplay.h"
#import "CGVirtualDisplayDescriptor.h"
#import "CGVirtualDisplayMode.h"
#import "CGVirtualDisplaySettings.h"

#import "VirtualDisplay.h"

static CGVirtualDisplaySettings *settingsForMode(int width, int height, BOOL hiDPI, double refreshRate) {
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI;
    settings.rotation = 0;

    if (hiDPI) {
        width /= 2;
        height /= 2;
    }
    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                      height:height
                                                                 refreshRate:MAX(15.0, MIN(refreshRate, 120.0))];
    settings.modes = @[mode];
    return settings;
}

id createVirtualDisplay(int width, int height, int ppi, BOOL hiDPI, NSString *name, unsigned int serialNum, double refreshRate) {
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    descriptor.name = name;

    // See System Preferences > Displays > Color > Open Profile > Apple display native information
    descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
    descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
    descriptor.maxPixelsHigh = height;
    descriptor.maxPixelsWide = width;
    descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / ppi, 25.4 * height / ppi);
    // Keep the legacy BetterCast identity tuple so existing macOS display
    // layouts and ColorSync profiles survive the ExtendCast bundle migration.
    // The serial is unique per receiver/density mode and the vendor is non-zero,
    // satisfying the requirements of newer macOS releases.
    descriptor.serialNum = serialNum;
    descriptor.serialNumber = serialNum;
    descriptor.productID = serialNum;
    descriptor.vendorID = 1;
    descriptor.terminationHandler = nil;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (![display applySettings:settingsForMode(width, height, hiDPI, refreshRate)])
        return nil;

    return display;
}

BOOL updateVirtualDisplay(id display, int width, int height, BOOL hiDPI, double refreshRate) {
    if (![display isKindOfClass:[CGVirtualDisplay class]])
        return NO;

    return [(CGVirtualDisplay *)display applySettings:settingsForMode(width, height, hiDPI, refreshRate)];
}
