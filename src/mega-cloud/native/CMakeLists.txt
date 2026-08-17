# BRIMSTONE MEGA Cloud native probe build.
cmake_minimum_required(VERSION 3.20)
project(BrimstoneMegaCloudProbe LANGUAGES CXX)

# BRIMSTONE CUSTOM CODE.
# v0.001cc is built as a child of the pinned MEGA SDK source tree so the probe
# links directly to the SDK's in-tree MEGA::SDKlib target. The SDK's install()
# step does not emit an SDKlibConfig.cmake package in this configuration, so a
# separate find_package(SDKlib) consumer is deliberately avoided.
if(NOT TARGET MEGA::SDKlib)
    message(FATAL_ERROR "BRIMSTONE: MEGA::SDKlib target is missing; configure this directory from the pinned MEGA SDK build")
endif()

add_executable(BrimstoneMegaCloudProbe
    BrimstoneMegaCloudProbe.cpp
)

target_compile_features(BrimstoneMegaCloudProbe PRIVATE cxx_std_17)
target_link_libraries(BrimstoneMegaCloudProbe PRIVATE MEGA::SDKlib)

set_target_properties(BrimstoneMegaCloudProbe PROPERTIES
    OUTPUT_NAME "brimstone-mega-cloud-probe"
)
