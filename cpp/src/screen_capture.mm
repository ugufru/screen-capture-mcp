#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AppKit/AppKit.h>

#include "screen_capture.h"

#include <stdexcept>

// ── helpers ──────────────────────────────────────────────────────────────

static std::string nsstring_to_std(NSString* s) {
    return s ? std::string([s UTF8String]) : "";
}

static std::vector<uint8_t> cgimage_to_png(CGImageRef image) {
    NSMutableData* pngData = [NSMutableData data];
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)pngData,
                                         (__bridge CFStringRef)UTTypePNG.identifier, 1, nil);
    if (!dest) {
        throw std::runtime_error("Failed to create PNG encoder");
    }
    CGImageDestinationAddImage(dest, image, nil);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);

    std::vector<uint8_t> result((uint8_t*)pngData.bytes,
                                (uint8_t*)pngData.bytes + pngData.length);
    return result;
}

// ── Async-to-sync bridge ─────────────────────────────────────────────────
// ScreenCaptureKit delivers results via XPC.  After the completion handler
// returns, the framework may release internal data (displays, windows).
// We must extract everything we need INSIDE the completion handler.
//
// The MCP message loop runs on a background thread.  We use
// dispatch_semaphore to wait; the completion handler fires on an internal
// XPC workqueue thread, so the semaphore never deadlocks.

// ── Public API ───────────────────────────────────────────────────────────

std::vector<DisplayInfo> list_displays() {
    __block std::vector<DisplayInfo> result;
    __block std::string error_msg;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:
        ^(SCShareableContent* content, NSError* error) {
            @autoreleasepool {
                if (error) {
                    error_msg = "Screen capture permission denied. "
                        "Enable in System Settings > Privacy & Security > Screen Recording. "
                        "Error: " + nsstring_to_std(error.localizedDescription);
                    dispatch_semaphore_signal(sem);
                    return;
                }
                if (!content) {
                    error_msg = "No shareable content returned";
                    dispatch_semaphore_signal(sem);
                    return;
                }

                // Extract all data NOW while objects are alive.
                NSArray<SCDisplay*>* displays = content.displays;

                // Get NSScreen info on the main queue synchronously.
                // We are on the XPC queue, so dispatch_sync to main is safe.
                __block NSArray<NSScreen*>* screens = nil;
                __block NSScreen* mainScreen = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    screens = [[NSScreen screens] copy];
                    mainScreen = [NSScreen mainScreen];
                });

                for (NSUInteger i = 0; i < displays.count; i++) {
                    SCDisplay* display = displays[i];
                    DisplayInfo info;
                    info.index = (int)i;
                    info.display_id = display.displayID;
                    info.width = (int)display.width;
                    info.height = (int)display.height;

                    info.name = "Display " + std::to_string(i);
                    info.is_main = false;
                    for (NSScreen* screen in screens) {
                        NSDictionary* desc = [screen deviceDescription];
                        NSNumber* screenNumber = desc[@"NSScreenNumber"];
                        if (screenNumber &&
                            [screenNumber unsignedIntValue] == display.displayID) {
                            info.name = nsstring_to_std(screen.localizedName);
                            info.is_main = (screen == mainScreen);
                            break;
                        }
                    }

                    result.push_back(info);
                }
            }
            dispatch_semaphore_signal(sem);
        }];

    long wait = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (wait != 0) {
        throw std::runtime_error(
            "Timeout fetching shareable content. "
            "Check System Settings > Privacy & Security > Screen Recording.");
    }
    if (!error_msg.empty()) {
        throw std::runtime_error(error_msg);
    }
    return result;
}

ScreenCaptureResult capture_screen(int display_index,
                                   int x, int y,
                                   int region_width, int region_height) {
    // Step 1: get shareable content and build filter/config inside callback
    __block SCContentFilter* filter = nil;
    __block SCStreamConfiguration* config = nil;
    __block std::string display_name;
    __block std::string error_msg;
    dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:
        ^(SCShareableContent* content, NSError* error) {
            @autoreleasepool {
                if (error) {
                    error_msg = "Screen capture permission denied. "
                        "Enable in System Settings > Privacy & Security > Screen Recording. "
                        "Error: " + nsstring_to_std(error.localizedDescription);
                    dispatch_semaphore_signal(sem1);
                    return;
                }
                if (!content) {
                    error_msg = "No shareable content returned";
                    dispatch_semaphore_signal(sem1);
                    return;
                }

                NSArray<SCDisplay*>* displays = content.displays;
                if (display_index < 0 || display_index >= (int)displays.count) {
                    error_msg = "Invalid display index: " +
                        std::to_string(display_index) +
                        ". Available: 0-" + std::to_string(displays.count - 1);
                    dispatch_semaphore_signal(sem1);
                    return;
                }

                SCDisplay* display = displays[display_index];
                filter = [[SCContentFilter alloc] initWithDisplay:display
                                                  excludingWindows:@[]];
                config = [[SCStreamConfiguration alloc] init];
                config.width = display.width;
                config.height = display.height;
                config.showsCursor = NO;

                if (region_width > 0 && region_height > 0) {
                    config.sourceRect = CGRectMake(x, y, region_width, region_height);
                    config.width = region_width;
                    config.height = region_height;
                }

                // Get display name from NSScreen on main thread
                dispatch_sync(dispatch_get_main_queue(), ^{
                    display_name = "Display " + std::to_string(display_index);
                    for (NSScreen* screen in [NSScreen screens]) {
                        NSDictionary* desc = [screen deviceDescription];
                        NSNumber* screenNumber = desc[@"NSScreenNumber"];
                        if (screenNumber &&
                            [screenNumber unsignedIntValue] == display.displayID) {
                            display_name = nsstring_to_std(screen.localizedName);
                            break;
                        }
                    }
                });
            }
            dispatch_semaphore_signal(sem1);
        }];

    long wait = dispatch_semaphore_wait(sem1,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (wait != 0) {
        throw std::runtime_error(
            "Timeout fetching shareable content. "
            "Check System Settings > Privacy & Security > Screen Recording.");
    }
    if (!error_msg.empty()) {
        throw std::runtime_error(error_msg);
    }

    // Step 2: capture screenshot (filter/config are retained by ARC)
    __block CGImageRef capturedImage = nil;
    dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);

    [SCScreenshotManager captureImageWithFilter:filter
                                  configuration:config
                              completionHandler:
        ^(CGImageRef image, NSError* error) {
            if (image) {
                capturedImage = image;
                CGImageRetain(capturedImage);
            }
            if (error) {
                error_msg = "Screenshot failed: " +
                    nsstring_to_std(error.localizedDescription);
            }
            dispatch_semaphore_signal(sem2);
        }];

    wait = dispatch_semaphore_wait(sem2,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (wait != 0) {
        throw std::runtime_error(
            "Timeout capturing screenshot. "
            "Check System Settings > Privacy & Security > Screen Recording.");
    }
    if (!error_msg.empty()) {
        throw std::runtime_error(error_msg);
    }
    if (!capturedImage) {
        throw std::runtime_error("No image captured");
    }

    auto png = cgimage_to_png(capturedImage);
    ScreenCaptureResult result;
    result.png_data = std::move(png);
    result.width = (int)CGImageGetWidth(capturedImage);
    result.height = (int)CGImageGetHeight(capturedImage);
    result.display_name = display_name;
    CGImageRelease(capturedImage);
    return result;
}

WindowCaptureResult capture_window(const std::string& app_name,
                                   const std::string& window_title) {
    // Step 1: find matching window and build filter/config inside callback
    __block SCContentFilter* filter = nil;
    __block SCStreamConfiguration* config = nil;
    __block std::string matched_app;
    __block std::string matched_title;
    __block std::string error_msg;
    dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:
        ^(SCShareableContent* content, NSError* error) {
            @autoreleasepool {
                if (error) {
                    error_msg = "Screen capture permission denied. "
                        "Enable in System Settings > Privacy & Security > Screen Recording. "
                        "Error: " + nsstring_to_std(error.localizedDescription);
                    dispatch_semaphore_signal(sem1);
                    return;
                }
                if (!content) {
                    error_msg = "No shareable content returned";
                    dispatch_semaphore_signal(sem1);
                    return;
                }

                NSArray<SCWindow*>* windows = content.windows;
                NSString* searchApp =
                    [[NSString stringWithUTF8String:app_name.c_str()] lowercaseString];
                NSString* searchTitle = window_title.empty() ? nil :
                    [[NSString stringWithUTF8String:window_title.c_str()] lowercaseString];

                SCWindow* matched = nil;
                NSMutableArray<NSString*>* searched = [NSMutableArray array];

                for (SCWindow* window in windows) {
                    if (!window.isOnScreen) continue;

                    NSString* windowAppName =
                        [window.owningApplication.applicationName lowercaseString];
                    NSString* windowTitleStr = [window.title lowercaseString];

                    if (!windowAppName) continue;

                    NSString* desc = [NSString stringWithFormat:@"%@ - %@",
                        window.owningApplication.applicationName,
                        window.title ?: @"(untitled)"];
                    [searched addObject:desc];

                    if ([windowAppName rangeOfString:searchApp].location == NSNotFound) {
                        continue;
                    }
                    if (searchTitle) {
                        if (!windowTitleStr ||
                            [windowTitleStr rangeOfString:searchTitle].location == NSNotFound) {
                            continue;
                        }
                    }

                    matched = window;
                    break;
                }

                if (!matched) {
                    error_msg = "No matching window found for app '" + app_name + "'";
                    if (!window_title.empty()) {
                        error_msg += " with title containing '" + window_title + "'";
                    }
                    error_msg += ". On-screen windows:\n";
                    for (NSString* s in searched) {
                        error_msg += "  - " + nsstring_to_std(s) + "\n";
                    }
                    dispatch_semaphore_signal(sem1);
                    return;
                }

                matched_app = nsstring_to_std(
                    matched.owningApplication.applicationName);
                matched_title = nsstring_to_std(matched.title);

                filter = [[SCContentFilter alloc]
                    initWithDesktopIndependentWindow:matched];
                config = [[SCStreamConfiguration alloc] init];
                config.width = (size_t)matched.frame.size.width;
                config.height = (size_t)matched.frame.size.height;
                config.showsCursor = NO;
            }
            dispatch_semaphore_signal(sem1);
        }];

    long wait = dispatch_semaphore_wait(sem1,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (wait != 0) {
        throw std::runtime_error(
            "Timeout fetching shareable content. "
            "Check System Settings > Privacy & Security > Screen Recording.");
    }
    if (!error_msg.empty()) {
        throw std::runtime_error(error_msg);
    }

    // Step 2: capture screenshot
    __block CGImageRef capturedImage = nil;
    dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);

    [SCScreenshotManager captureImageWithFilter:filter
                                  configuration:config
                              completionHandler:
        ^(CGImageRef image, NSError* err) {
            if (image) {
                capturedImage = image;
                CGImageRetain(capturedImage);
            }
            if (err) {
                error_msg = "Screenshot failed: " +
                    nsstring_to_std(err.localizedDescription);
            }
            dispatch_semaphore_signal(sem2);
        }];

    wait = dispatch_semaphore_wait(sem2,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (wait != 0) {
        throw std::runtime_error(
            "Timeout capturing screenshot. "
            "Check System Settings > Privacy & Security > Screen Recording.");
    }
    if (!error_msg.empty()) {
        throw std::runtime_error(error_msg);
    }
    if (!capturedImage) {
        throw std::runtime_error("No image captured");
    }

    auto png = cgimage_to_png(capturedImage);
    WindowCaptureResult result;
    result.png_data = std::move(png);
    result.width = (int)CGImageGetWidth(capturedImage);
    result.height = (int)CGImageGetHeight(capturedImage);
    result.window_title = matched_title;
    result.app_name = matched_app;
    CGImageRelease(capturedImage);
    return result;
}
