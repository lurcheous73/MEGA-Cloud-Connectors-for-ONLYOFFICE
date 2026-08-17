# BRIMSTONE MEGA Cloud native probe build.
cmake_minimum_required(VERSION 3.20)
project(BrimstoneMegaCloudProbe LANGUAGES CXX)

find_package(SDKlib REQUIRED)

add_executable(BrimstoneMegaCloudProbe
    BrimstoneMegaCloudProbe.cpp
)

target_compile_features(BrimstoneMegaCloudProbe PRIVATE cxx_std_17)
target_link_libraries(BrimstoneMegaCloudProbe PRIVATE MEGA::SDKlib)

set_target_properties(BrimstoneMegaCloudProbe PROPERTIES
    OUTPUT_NAME "brimstone-mega-cloud-probe"
)
