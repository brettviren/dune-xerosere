# Superbuild for the ddm umbrella packages.
#
# The packages under this directory depend on each other through
# `find_package(<pkg> CONFIG REQUIRED)`, i.e. each one expects its in-tree
# siblings to already be *installed* (they export package config files).  A
# plain add_subdirectory() aggregation therefore cannot satisfy those lookups.
#
# Instead this is a classic CMake "superbuild": every package is configured,
# built and installed into one shared prefix via ExternalProject_Add, in
# dependency order, and that prefix is placed on CMAKE_PREFIX_PATH so a
# downstream package's find_package() resolves its just-installed upstreams.
#
# The inter-package dependency graph is DISCOVERED, not hand-written: each
# package already declares its dependencies as find_package() calls, and a
# dependency on a sibling is simply a find_package() name that matches another
# package's project() name.  We scan the CMakeLists.txt files for both and
# intersect.  External deps (WireCell, phlex, Arrow, HDF5, TBB, Boost, spdlog)
# are the find_package names that match no sibling; they come from
# CMAKE_PREFIX_PATH (eg as provided by a Spack view direcotry).
#
# Usage:
#   cmake -S devel -B builds/devel [-DCMAKE_INSTALL_PREFIX=...]
#   cmake --build builds/devel
#
# Sub-packages are built with Ninja when available (fast incremental/no-op
# rebuilds) and installed with an RPATH that resolves both the shared prefix's
# lib and the external Spack-view libs, so <prefix>/bin executables run as-is
# (verify with `ldd <prefix>/bin/daq_hdf_to_arrow`). After changing a sub-package
# just re-run `cmake --build builds/super`; BUILD_ALWAYS ensures the change is
# picked up (see the note on ExternalProject_Add below).
#
cmake_minimum_required(VERSION 3.21)
project(xerosere VERSION 0.1.0 LANGUAGES NONE)

include(ExternalProject)

# Packages NOT to build here (not CMake / provided externally).
set(XEROSERE_EXCLUDE wire-cell-toolkit phlex)

# Shared install prefix for all sub-packages.  Defaults to <build>/install so
# nothing pollutes the source tree unless the user overrides CMAKE_INSTALL_PREFIX.
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/install"
      CACHE PATH "Shared install prefix for xerosere superbuild" FORCE)
endif()
set(XEROSERE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# CMAKE_PREFIX_PATH seen by every sub-build: the shared install prefix (so
# already-installed siblings are found) plus whatever was passed to this build
# (the Spack view, etc.).  ExternalProject mangles ';' in lists, so join with a
# private separator and tell each sub-build to split on it.
set(_xerosere_prefix_path "${XEROSERE_INSTALL_PREFIX}")
if(CMAKE_PREFIX_PATH)
  list(APPEND _xerosere_prefix_path ${CMAKE_PREFIX_PATH})
endif()
string(REPLACE ";" "|" XEROSERE_PREFIX_PATH "${_xerosere_prefix_path}")

# Cache variables forwarded verbatim to every sub-build.
set(XEROSERE_FORWARDED_CACHE_ARGS
  -DCMAKE_INSTALL_PREFIX:PATH=${XEROSERE_INSTALL_PREFIX}
  -DCMAKE_PREFIX_PATH:STRING=${XEROSERE_PREFIX_PATH}
  -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
  -DCMAKE_CXX_COMPILER:STRING=${CMAKE_CXX_COMPILER}
  -DCMAKE_C_COMPILER:STRING=${CMAKE_C_COMPILER}
  -DCMAKE_CXX_STANDARD:STRING=${CMAKE_CXX_STANDARD}
  -DBUILD_SHARED_LIBS:BOOL=${BUILD_SHARED_LIBS}
  # CMake >=3.30 removed the bundled FindBoost module (policy CMP0167). Default
  # it to NEW so sub-packages' find_package(Boost ...) use Boost's own config
  # (BoostConfig) from the Spack view instead of warning about the dead module.
  -DCMAKE_POLICY_DEFAULT_CMP0167:STRING=NEW
  # Installed binaries/libs must locate their siblings (in the shared prefix's
  # lib) AND the external Spack-view libs at runtime. Bake an install RPATH:
  #   * the shared lib dir explicitly (so e.g. bin/daq_hdf_to_arrow finds
  #     lib/libdune_daq_*.so, lib/libwire_cell_arrow.so, ...), and
  #   * USE_LINK_PATH adds the directory of every linked library that lives
  #     outside the build tree -> the Arrow/WireCell/HDF5/Boost view libs and the
  #     gcc15 libstdc++.
  # Without this, CMake strips the build-tree RPATH on install and the installed
  # binary shows "not found" in ldd. (lib + lib64 cover either GNUInstallDirs
  # layout; '|' is the LIST_SEPARATOR, restored to ';' for each sub-build.)
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH:BOOL=TRUE
  -DCMAKE_INSTALL_RPATH:STRING=${XEROSERE_INSTALL_PREFIX}/lib|${XEROSERE_INSTALL_PREFIX}/lib64
)

# Build the sub-projects with Ninja when it is available: its incremental/no-op
# rebuild check is far faster than Make's, which (with BUILD_ALWAYS below) runs
# for every package on every invocation. Force it regardless of the outer
# generator; fall back to inheriting the outer generator when ninja is absent.
find_program(XEROSERE_NINJA NAMES ninja ninja-build)
if(XEROSERE_NINJA)
  set(XEROSERE_SUB_GENERATOR "Ninja")
else()
  set(XEROSERE_SUB_GENERATOR "${CMAKE_GENERATOR}")
endif()
message(STATUS "xerosere super: sub-build generator = ${XEROSERE_SUB_GENERATOR}")

# --- Discover packages and their declared dependencies -----------------------
#
# For each immediate subdirectory holding a CMakeLists.txt:
#   * read the project() name  -> the package's exported (find_package) name
#   * read every find_package() name it requests
# We key everything by project() name and remember the subdir.

file(GLOB _entries RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}"
     "${CMAKE_CURRENT_SOURCE_DIR}/*")

set(XEROSERE_PKGS "")                       # list of project() names we will build
foreach(_dir IN LISTS _entries)
  set(_cml "${CMAKE_CURRENT_SOURCE_DIR}/${_dir}/CMakeLists.txt")
  if(NOT IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${_dir}")
    continue()
  endif()
  if(_dir IN_LIST XEROSERE_EXCLUDE OR NOT EXISTS "${_cml}")
    continue()
  endif()

  # project(<name> ...)  -- first token after the paren.
  file(STRINGS "${_cml}" _proj_lines REGEX "^[ \t]*project[ \t]*\\(")
  set(_name "")
  foreach(_line IN LISTS _proj_lines)
    if(_line MATCHES "^[ \t]*project[ \t]*\\([ \t]*([A-Za-z0-9_]+)")
      set(_name "${CMAKE_MATCH_1}")
      break()
    endif()
  endforeach()
  if(NOT _name)
    message(WARNING "xerosere super: no project() found in ${_cml}, skipping")
    continue()
  endif()

  # find_package(<name> ...)  -- collect the requested package names.
  file(STRINGS "${_cml}" _fp_lines REGEX "^[ \t]*find_package[ \t]*\\(")
  set(_reqs "")
  foreach(_line IN LISTS _fp_lines)
    if(_line MATCHES "^[ \t]*find_package[ \t]*\\([ \t]*([A-Za-z0-9_]+)")
      list(APPEND _reqs "${CMAKE_MATCH_1}")
    endif()
  endforeach()

  list(APPEND XEROSERE_PKGS "${_name}")
  set(XEROSERE_${_name}_SUBDIR "${_dir}")
  set(XEROSERE_${_name}_REQS "${_reqs}")
endforeach()

# --- Register each package, depending only on siblings it find_package()s -----
#
# Two passes so DEPENDS targets always exist: create all ExternalProjects first,
# then wire add_dependencies() using the discovered graph.  An internal
# dependency is a requested name that is itself one of the packages we build.

foreach(_name IN LISTS XEROSERE_PKGS)
  ExternalProject_Add(${_name}
    PREFIX            "${CMAKE_BINARY_DIR}/${_name}"
    SOURCE_DIR        "${CMAKE_CURRENT_SOURCE_DIR}/${XEROSERE_${_name}_SUBDIR}"
    INSTALL_DIR       "${XEROSERE_INSTALL_PREFIX}"
    LIST_SEPARATOR    "|"
    CMAKE_GENERATOR   "${XEROSERE_SUB_GENERATOR}"
    CMAKE_CACHE_ARGS  ${XEROSERE_FORWARDED_CACHE_ARGS}
    # ExternalProject cannot watch source files, so it must always RE-INVOKE each
    # sub-build; that sub-build (Ninja/Make) then uses timestamps to compile only
    # what actually changed. This is what keeps install/ consistent after a source
    # edit -- dropping it would skip changed packages and ship stale artifacts.
    # The per-package no-op cost is what Ninja (above) makes negligible.
    BUILD_ALWAYS      TRUE
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD     TRUE
    USES_TERMINAL_INSTALL   TRUE
  )
endforeach()

foreach(_name IN LISTS XEROSERE_PKGS)
  set(_internal "")
  foreach(_req IN LISTS XEROSERE_${_name}_REQS)
    if(_req IN_LIST XEROSERE_PKGS AND NOT _req STREQUAL _name)
      list(APPEND _internal "${_req}")
    endif()
  endforeach()
  if(_internal)
    add_dependencies(${_name} ${_internal})
    message(STATUS "xerosere super: ${_name} depends on ${_internal}")
  else()
    message(STATUS "xerosere super: ${_name} (no in-tree dependencies)")
  endif()
endforeach()
