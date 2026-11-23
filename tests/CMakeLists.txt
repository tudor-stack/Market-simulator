include(FetchContent)

FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.15.2
)

FetchContent_MakeAvailable(googletest)

add_executable(engine_tests
    engine_test.cpp
)

target_link_libraries(engine_tests PRIVATE gtest_main)
target_include_directories(engine_tests PRIVATE ${CMAKE_SOURCE_DIR}/engine/src)

include(GoogleTest)
gtest_discover_tests(engine_tests)
