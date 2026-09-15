cmake_minimum_required(VERSION 3.14)
project(ishkafel_renderer LANGUAGES CXX)

set(RENDERER_BINARY_NAME "ishkafel_renderer" PARENT_SCOPE)

add_executable(ishkafel_renderer "main.cpp")
apply_standard_settings(ishkafel_renderer)
target_compile_definitions(ishkafel_renderer PRIVATE "NOMINMAX")
target_link_libraries(ishkafel_renderer PRIVATE flutter flutter_wrapper_app)
target_include_directories(ishkafel_renderer PRIVATE "${CMAKE_SOURCE_DIR}")
add_dependencies(ishkafel_renderer flutter_assemble)
