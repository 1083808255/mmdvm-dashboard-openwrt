cmake_minimum_required(VERSION 3.20)
project(dmrstream LANGUAGES C CXX)

# 使用随包携带的固定版本依赖，固件构建过程不需要联网。
set(FETCHCONTENT_SOURCE_DIR_MBELIB_PFFFT
    "${CMAKE_CURRENT_SOURCE_DIR}/vendor/pffft"
    CACHE PATH "" FORCE
)
set(FETCHCONTENT_FULLY_DISCONNECTED ON CACHE BOOL "" FORCE)
set(MBELIB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(MBELIB_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(MBELIB_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(MBELIB_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(MBELIB_ENABLE_NATIVE OFF CACHE BOOL "" FORCE)
set(MBELIB_WARNINGS_AS_ERRORS OFF CACHE BOOL "" FORCE)
# OpenWrt 已注入工具链适用的加固参数；mbelib-neo 额外的 stack-clash 参数不支持 MIPS16。
set(MBELIB_ENABLE_HARDENING OFF CACHE BOOL "" FORCE)

add_subdirectory(vendor/mbelib-neo EXCLUDE_FROM_ALL)

add_executable(dmrstreamd
    dmrstreamd.cpp
    vendor/MMDVMHost/Golay24128.cpp
    vendor/MMDVMHost/Hamming.cpp
)
target_compile_features(dmrstreamd PRIVATE cxx_std_11)
target_include_directories(dmrstreamd PRIVATE vendor/MMDVMHost)
target_link_libraries(dmrstreamd PRIVATE mbe-static m)
if(CMAKE_EXE_LINKER_FLAGS MATCHES "-static")
    # OpenWrt 的全静态 libstdc++ 需要显式链接异常展开运行库。
    target_link_libraries(dmrstreamd PRIVATE gcc_eh gcc)
endif()
