
# si_add_module(<name> [SOURCES <files>...] [DEPS <targets>...])
# Creates si_<name> (alias si::<name>), public include dir <module>/include.
# Without SOURCES it's header-only (INTERFACE); adding the first .cpp only means passing SOURCES.
function(si_add_module name)
    cmake_parse_arguments(ARG "" "" "SOURCES;DEPS" ${ARGN})
    set(target si_${name})

    if(ARG_SOURCES)
        add_library(${target} STATIC ${ARG_SOURCES})
        target_include_directories(${target} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
        target_link_libraries(${target} PUBLIC ${ARG_DEPS})
    else()
        add_library(${target} INTERFACE)
        target_include_directories(${target} INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/include)
        target_link_libraries(${target} INTERFACE ${ARG_DEPS})
    endif()

    add_library(si::${name} ALIAS ${target})
endfunction()