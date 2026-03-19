#pragma once
#include <cstdint>
#include <string>
#include <vector>

struct DisplayInfo {
    int index;
    uint32_t display_id;
    std::string name;
    int width;
    int height;
    bool is_main;
};

struct ScreenCaptureResult {
    std::vector<uint8_t> png_data;
    int width;
    int height;
    std::string display_name;
};

struct WindowCaptureResult {
    std::vector<uint8_t> png_data;
    int width;
    int height;
    std::string window_title;
    std::string app_name;
};

// Enumerate available displays
std::vector<DisplayInfo> list_displays();

// Capture a full display or region (x/y/width/height of 0 = full display)
ScreenCaptureResult capture_screen(int display_index = 0,
                                   int x = 0, int y = 0,
                                   int width = 0, int height = 0);

// Capture a window by app name and optional title substring
WindowCaptureResult capture_window(const std::string& app_name,
                                   const std::string& window_title = "");
