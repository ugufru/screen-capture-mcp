cmake_minimum_required(VERSION 3.20)
project(screen-capture-mcp LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

# Fetch nlohmann/json
include(FetchContent)
FetchContent_Declare(
    json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.11.3
)
FetchContent_MakeAvailable(json)

add_executable(screen-capture-mcp
    src/main.mm
    src/mcp_server.cpp
    src/screen_capture.mm
)

target_link_libraries(screen-capture-mcp PRIVATE
    nlohmann_json::nlohmann_json
    "-framework ScreenCaptureKit"
    "-framework CoreGraphics"
    "-framework Foundation"
    "-framework ImageIO"
    "-framework UniformTypeIdentifiers"
    "-framework AppKit"
)

target_include_directories(screen-capture-mcp PRIVATE src)
