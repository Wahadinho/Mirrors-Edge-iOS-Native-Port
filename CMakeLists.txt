cmake_minimum_required(VERSION 3.24)
project(MirrorsEdgeIOS LANGUAGES C CXX OBJCXX)

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_ARCHITECTURES "arm64")
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0")

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SDL3_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../SDL/include")
set(SDL3_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../SDL/build-ios/Release-iphoneos/libSDL3.a")

set(LIFTED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/lifted")
include("${LIFTED_DIR}/lifted_sources.cmake")

add_library(me_lifted STATIC ${LIFTED_SOURCES})
target_include_directories(me_lifted PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/host_macos/runtime")
target_compile_options(me_lifted PRIVATE
    -O2 -g0 -fwrapv -ffp-contract=off -fno-strict-aliasing
    -Wno-unused-label -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-function
)

if(PHYSXCORE_LIFTED)
    set_source_files_properties(${PHYSXCORE_LIFTED} PROPERTIES
        COMPILE_DEFINITIONS "X86_RESTRICT=restrict;X86_FLOAT_PLAIN=1;X86_X87_LOCAL=1;X86_X87_SLOTS=1"
    )
endif()

set(RUNTIME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/host_macos/runtime")
set(HOST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/host_macos/host")
set(SHATTER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/host_macos/shatter")

set(RUNTIME_SOURCES
    "${RUNTIME_DIR}/rt_core.c"
    "${RUNTIME_DIR}/rt_kernel32.c"
    "${RUNTIME_DIR}/rt_sync.c"
    "${RUNTIME_DIR}/rt_files.c"
    "${RUNTIME_DIR}/rt_user32.c"
    "${RUNTIME_DIR}/rt_d3d9.c"
    "${RUNTIME_DIR}/rt_d3d9_gen.c"
    "${RUNTIME_DIR}/rt_physx_support.c"
    "${RUNTIME_DIR}/rt_dinput.c"
    "${RUNTIME_DIR}/rt_ue3.c"
    "${RUNTIME_DIR}/rt_openal.c"
    "${RUNTIME_DIR}/rt_stubs.c"
    "${RUNTIME_DIR}/rt_main.c"
    "${HOST_DIR}/rt_host_macos.c"
    "${HOST_DIR}/ios_virtual_pad.mm"
)

set_source_files_properties("${RUNTIME_DIR}/rt_main.c" PROPERTIES COMPILE_DEFINITIONS "main=me_pc_main")

set(SHATTER_SOURCES
    "${SHATTER_DIR}/solver/fluid/fluid.cpp"
    "${SHATTER_DIR}/solver/cloth/cloth.cpp"
    "${SHATTER_DIR}/solver/cloth/cloth_attach.cpp"
    "${SHATTER_DIR}/solver/cloth/cloth_edgeshape.cpp"
    "${SHATTER_DIR}/solver/cloth/cloth_mesh.cpp"
    "${SHATTER_DIR}/solver/cloth/cloth_self.cpp"
    "${SHATTER_DIR}/solver/cloth/cloth_selftri.cpp"
    "${SHATTER_DIR}/solver/cloth/cloth_state.cpp"
    "${SHATTER_DIR}/shim/fluid_ours.cpp"
    "${SHATTER_DIR}/shim/cloth_ours.cpp"
    "${SHATTER_DIR}/shim/scene_read.cpp"
    "${SHATTER_DIR}/shim/coverage.cpp"
    "${SHATTER_DIR}/port/bridge.cpp"
    "${SHATTER_DIR}/port/game_hooks_port.cpp"
)

add_library(me_shatter STATIC ${SHATTER_SOURCES})
target_include_directories(me_shatter PRIVATE
    "${RUNTIME_DIR}"
    "${SHATTER_DIR}/port"
    "${SHATTER_DIR}/port/neon"
    "${SHATTER_DIR}/shim"
)
target_compile_options(me_shatter PRIVATE -O2 -g0 -fwrapv -ffp-contract=off -fno-strict-aliasing)

set(DXBC_SPV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dxbc-spirv")
file(GLOB_RECURSE DXBC_SPV_SOURCES "${DXBC_SPV_DIR}/*.cpp")
list(FILTER DXBC_SPV_SOURCES EXCLUDE REGEX ".*test.*|.*main.*")

add_library(dxbc_spv_sm3 STATIC ${DXBC_SPV_SOURCES})
target_include_directories(dxbc_spv_sm3 PUBLIC "${DXBC_SPV_DIR}")
target_compile_definitions(dxbc_spv_sm3 PUBLIC DXBC_SPV_ENABLE_SM3 DXBC_SPV_ENABLE_SPIRV)
target_compile_options(dxbc_spv_sm3 PRIVATE -O2 -g0 -Wno-unused-parameter -Wno-missing-field-initializers)

set(SPIRV_CROSS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/spirv-cross")
set(SPIRV_CROSS_INCLUDE_DIR "${SPIRV_CROSS_DIR}/include")
add_library(spirv_cross STATIC
    "${SPIRV_CROSS_DIR}/src/spirv_cross.cpp"
    "${SPIRV_CROSS_DIR}/src/spirv_parser.cpp"
    "${SPIRV_CROSS_DIR}/src/spirv_cross_parsed_ir.cpp"
    "${SPIRV_CROSS_DIR}/src/spirv_cfg.cpp"
    "${SPIRV_CROSS_DIR}/src/spirv_glsl.cpp"
    "${SPIRV_CROSS_DIR}/src/spirv_msl.cpp"
)
target_include_directories(spirv_cross
    PUBLIC "${SPIRV_CROSS_INCLUDE_DIR}"
    PRIVATE "${SPIRV_CROSS_INCLUDE_DIR}/spirv_cross"
)
target_compile_options(spirv_cross PRIVATE -O2 -g0 -Wno-unused-parameter)

set(D3D9_METAL_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/core/mtl_d3d9_entry.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/core/mtl_d3d9_device.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/resources/mtl_format.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/resources/mtl_resources.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/pipeline/mtl_pipeline_cache.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/shaders/mtl_shader_compiler.mm"
)

add_executable(MirrorsEdgeIOS MACOSX_BUNDLE
    ${RUNTIME_SOURCES}
    ${D3D9_METAL_SOURCES}
    
    
)

set_target_properties(MirrorsEdgeIOS PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios_packaging/Info.plist"
    OUTPUT_NAME "MirrorsEdgeIOS"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
    XCODE_ATTRIBUTE_INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
    XCODE_ATTRIBUTE_INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)

target_include_directories(MirrorsEdgeIOS PRIVATE
    "${SDL3_INCLUDE_DIR}"
    "${RUNTIME_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/resources"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/pipeline"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/d3d9_metal/shaders"
    "${SPIRV_CROSS_INCLUDE_DIR}"
)

target_compile_definitions(MirrorsEdgeIOS PRIVATE RT_SHATTER=1)
target_compile_options(MirrorsEdgeIOS PRIVATE
    $<$<COMPILE_LANGUAGE:C>:-O2 -g0 -fwrapv -ffp-contract=off -fno-strict-aliasing>
    $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-O2 -g0 -fobjc-arc>
)

target_link_libraries(MirrorsEdgeIOS PRIVATE
    me_shatter
    me_lifted
    "${SDL3_LIBRARY}"
    dxbc_spv_sm3
    spirv_cross
        "-framework CoreVideo"
    "-framework OpenGLES"
    "-framework CoreBluetooth"
    "-framework CoreServices"
    "-framework ImageIO"
    "-framework MobileCoreServices"
    "-framework UserNotifications"
    "-framework UIKit"
    "-framework Foundation"
    "-framework Metal"
    "-framework QuartzCore"
    "-framework CoreGraphics"
    "-framework AudioToolbox"
    "-framework AVFoundation"
    "-framework CoreAudio"
    "-framework CoreMotion"
    "-framework GameController"
    "-framework CoreHaptics"
    "-framework CoreMedia"
    "-framework Security"
    "-framework SystemConfiguration"
    "-liconv"
    m
    pthread
)

target_link_options(MirrorsEdgeIOS PRIVATE "-Wl,-stack_size,0x4000000")
