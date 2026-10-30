cmake_minimum_required(VERSION 3.21)

project(WorldBuilderTools VERSION 1.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# RED4ext plugins are loaded into the game process, so keep the CRT static: the game install must
# not need a VC++ redistributable for this DLL to load.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_subdirectory(vendor/RED4ext.SDK)

add_library(WorldBuilderTools SHARED src/Main.cpp)
target_link_libraries(WorldBuilderTools PRIVATE RED4ext.SDK)

# RED4ext discovers plugins as red4ext/plugins/<dir>/<anything>.dll; the name is what shows up in
# the RED4ext log, so keep it stable.
set_target_properties(WorldBuilderTools PROPERTIES
    OUTPUT_NAME "WorldBuilderTools"
    PREFIX ""
)

if (MSVC)
    target_compile_options(WorldBuilderTools PRIVATE /W4 /permissive-)
endif()

# Drop the built DLL straight into the mod's deploy tree, so packing needs no extra copy step.
set(WBT_DEPLOY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../resources/red4ext/plugins/WorldBuilder")

add_custom_command(TARGET WorldBuilderTools POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${WBT_DEPLOY_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:WorldBuilderTools>" "${WBT_DEPLOY_DIR}/WorldBuilderTools.dll"
    COMMENT "Deploying WorldBuilderTools.dll to source/resources/red4ext/plugins/WorldBuilder"
)
