cmake_minimum_required(VERSION 3.20)
project(market-simulator LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(market-simulator engine/src/main.cpp)

enable_testing()
add_subdirectory(tests)

# Auto-install pre-commit hooks
find_program(PRE_COMMIT pre-commit)
if(PRE_COMMIT)
    execute_process(
        COMMAND ${PRE_COMMIT} install
        COMMAND ${PRE_COMMIT} install --hook-type commit-msg
        COMMAND ${PRE_COMMIT} install --hook-type pre-push
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    )
    message(STATUS "pre-commit hooks installed")
else()
    message(WARNING "pre-commit not found — install it: pip install pre-commit")
endif()
