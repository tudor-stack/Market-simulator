add_executable(market-simulator src/main.cpp)
target_link_libraries(market-simulator PRIVATE si::gateway)