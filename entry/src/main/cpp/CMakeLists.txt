cmake_minimum_required(VERSION 3.5.0)
project(blowfish)

add_library(blowfish SHARED blowfish_core.cpp blowfish.cpp)

target_include_directories(blowfish PRIVATE
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

target_link_libraries(blowfish PUBLIC
    libhilog_ndk.z.so
    libace_napi.z.so
)
