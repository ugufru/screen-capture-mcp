#include "base64.h"
#include "mcp_server.h"
#include "screen_capture.h"

#include <nlohmann/json.hpp>

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>

using json = nlohmann::json;

int main() {
    @autoreleasepool {

    // Initialize NSApplication so AppKit/ScreenCaptureKit work in a CLI tool.
    [NSApplication sharedApplication];

    __block McpServer server("screen-capture", "1.1.0");

    // ── list_displays ─────────────────────────────────────────────────
    server.add_tool(
        "list_displays",
        "List available displays with their index, resolution, and whether "
        "they are the main display.",
        {{"type", "object"}, {"properties", json::object()}},
        [](const json& /*args*/) -> json {
            auto displays = list_displays();
            json content = json::array();
            json display_list = json::array();
            for (auto& d : displays) {
                display_list.push_back(
                    {{"index", d.index},
                     {"display_id", d.display_id},
                     {"name", d.name},
                     {"width", d.width},
                     {"height", d.height},
                     {"is_main", d.is_main}});
            }
            content.push_back(
                {{"type", "text"},
                 {"text", display_list.dump(2)}});
            return content;
        });

    // ── capture_screen ────────────────────────────────────────────────
    json screen_schema = {
        {"type", "object"},
        {"properties",
         {{"display_index",
           {{"type", "integer"},
            {"default", 0},
            {"description", "Display index from list_displays"}}},
          {"x",
           {{"type", "integer"},
            {"description", "Region X offset (optional)"}}},
          {"y",
           {{"type", "integer"},
            {"description", "Region Y offset (optional)"}}},
          {"width",
           {{"type", "integer"},
            {"description", "Region width (optional)"}}},
          {"height",
           {{"type", "integer"},
            {"description", "Region height (optional)"}}}}}};

    server.add_tool(
        "capture_screen",
        "Capture a screenshot of a display or region. Returns the image "
        "for Claude to see.",
        screen_schema,
        [](const json& args) -> json {
            int idx = args.value("display_index", 0);
            int x = args.value("x", 0);
            int y = args.value("y", 0);
            int w = args.value("width", 0);
            int h = args.value("height", 0);

            auto result = capture_screen(idx, x, y, w, h);
            std::string b64 = base64_encode(result.png_data);

            json content = json::array();
            content.push_back(
                {{"type", "text"},
                 {"text", "Screenshot of " + result.display_name +
                          " (" + std::to_string(result.width) + "x" +
                          std::to_string(result.height) + ")"}});
            content.push_back(
                {{"type", "image"},
                 {"data", b64},
                 {"mimeType", "image/png"}});
            return content;
        });

    // ── capture_window ────────────────────────────────────────────────
    json window_schema = {
        {"type", "object"},
        {"properties",
         {{"app_name",
           {{"type", "string"},
            {"description",
             "Application name (case-insensitive substring match)"}}},
          {"window_title",
           {{"type", "string"},
            {"description",
             "Window title filter (case-insensitive substring, optional)"}}}}},
        {"required", json::array({"app_name"})}};

    server.add_tool(
        "capture_window",
        "Capture a screenshot of a specific application window. "
        "Returns the image for Claude to see.",
        window_schema,
        [](const json& args) -> json {
            std::string app = args.at("app_name").get<std::string>();
            std::string title = args.value("window_title", "");

            auto result = capture_window(app, title);
            std::string b64 = base64_encode(result.png_data);

            json content = json::array();
            content.push_back(
                {{"type", "text"},
                 {"text", "Window: " + result.app_name +
                          " - " + result.window_title +
                          " (" + std::to_string(result.width) + "x" +
                          std::to_string(result.height) + ")"}});
            content.push_back(
                {{"type", "image"},
                 {"data", b64},
                 {"mimeType", "image/png"}});
            return content;
        });

    // Run the MCP stdin loop on a background thread so the main thread
    // can service the NSRunLoop (required by ScreenCaptureKit callbacks).
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        server.run();
        exit(0);
    });

    // Run the NSApplication event loop so AppKit and ScreenCaptureKit
    // callbacks are delivered on the main thread.
    [NSApp run];

    } // @autoreleasepool
    return 0;
}
