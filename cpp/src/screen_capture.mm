#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AppKit/AppKit.h>

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include "screen_capture.h"

#include <stdexcept>

// ── SCStream single-frame delegate ──────────────────────────────────────

@interface SingleFrameCapture : NSObject <SCStreamOutput>
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, assign) CGImageRef capturedImage;
@end

@implementation SingleFrameCapture

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    if (self.capturedImage) return; // first frame only

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    void* base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(pixelBuffer);

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(
        base, w, h, 8, bpr, cs,
        kCGBitmapByteOrder32Little | (uint32_t)kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);

    if (ctx) {
        self.capturedImage = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    dispatch_semaphore_signal(self.semaphore);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)dealloc {
    if (_capturedImage) {
        CGImageRelease(_capturedImage);
    }
}
#pragma clang diagnostic pop

@end

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
    // Step 1: get display info from ScreenCaptureKit (for enumeration)
    __block CGDirectDisplayID captured_display_id = 0;
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
                captured_display_id = display.displayID;

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

    // Step 2: capture using CoreGraphics (synchronous, no XPC needed)
    CGImageRef capturedImage;
    if (region_width > 0 && region_height > 0) {
        CGRect region = CGRectMake(x, y, region_width, region_height);
        capturedImage = CGDisplayCreateImageForRect(captured_display_id, region);
    } else {
        capturedImage = CGDisplayCreateImage(captured_display_id);
    }
    if (!capturedImage) {
        throw std::runtime_error("Failed to capture display");
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
                config.pixelFormat = kCVPixelFormatType_32BGRA;
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

    // Step 2: capture via SCStream (grab first frame then stop)
    // SCScreenshotManager's completion handler is unreliable in CLI processes
    // on macOS 15. SCStream's frame delivery is more reliable.
    SingleFrameCapture* frameCapture = [[SingleFrameCapture alloc] init];
    frameCapture.semaphore = dispatch_semaphore_create(0);

    NSError* streamError = nil;
    SCStream* stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:config
                                               delegate:nil];
    [stream addStreamOutput:frameCapture
                       type:SCStreamOutputTypeScreen
          sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                      error:&streamError];
    if (streamError) {
        throw std::runtime_error("Failed to configure stream: " +
                                 nsstring_to_std(streamError.localizedDescription));
    }

    // Start the stream
    dispatch_semaphore_t startSem = dispatch_semaphore_create(0);
    __block NSError* startError = nil;
    [stream startCaptureWithCompletionHandler:^(NSError* error) {
        startError = error;
        dispatch_semaphore_signal(startSem);
    }];

    wait = dispatch_semaphore_wait(startSem,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (wait != 0) {
        throw std::runtime_error(
            "Timeout starting stream. "
            "Check System Settings > Privacy & Security > Screen Recording.");
    }
    if (startError) {
        throw std::runtime_error("Failed to start stream: " +
                                 nsstring_to_std(startError.localizedDescription));
    }

    // Wait for first frame
    wait = dispatch_semaphore_wait(frameCapture.semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    // Stop the stream regardless
    dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError*) {
        dispatch_semaphore_signal(stopSem);
    }];
    dispatch_semaphore_wait(stopSem,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (wait != 0) {
        throw std::runtime_error("Timeout waiting for window frame");
    }

    CGImageRef capturedImage = frameCapture.capturedImage;
    if (!capturedImage) {
        throw std::runtime_error("No image captured from stream");
    }

    auto png = cgimage_to_png(capturedImage);
    WindowCaptureResult result;
    result.png_data = std::move(png);
    result.width = (int)CGImageGetWidth(capturedImage);
    result.height = (int)CGImageGetHeight(capturedImage);
    result.window_title = matched_title;
    result.app_name = matched_app;
    return result;
}
