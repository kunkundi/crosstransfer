-- CrossTransfer: root build.
--   minirtc              specialised data-only transport engine (static)
--   crosstransfer_core   share / receive state machines, block protocol, C API (static)
--   ct_cli               command line client (binary)
--   core_tests           unit tests (binary, doctest)
--   crosstransfer_native shared umbrella for Flutter FFI (minirtc + core)
set_project("crosstransfer")
set_version("0.1.0")

add_rules("mode.release", "mode.debug")
set_languages("c++17")
set_encodings("utf-8")

-- Match Flutter's Windows CRT and propagate it to all native dependencies.
if is_plat("windows") then
    set_runtimes(is_mode("debug") and "MDd" or "MD")
end

-- macOS deployment floor for the Flutter app is 12.0 (see app/macos/Podfile);
-- pass `--target_minver=12.0` at configure time (tools/build_native.sh does).

includes("minirtc")

add_requires("nlohmann_json 3.11.3", "spdlog 1.14.1",
    {system = false, configs = {shared = false}})
add_requires("openssl3 3.3.2", {system = false, configs = {shared = false}})

option("ct_cli")
    set_default(true)
    set_showmenu(true)
    set_description("Build the ct_cli command line client")
option_end()

option("ct_tests")
    set_default(true)
    set_showmenu(true)
    set_description("Build core unit tests (doctest)")
option_end()

option("ct_native")
    set_default(false)
    set_showmenu(true)
    set_description("Build the crosstransfer_native shared library for Flutter FFI")
option_end()

if has_config("ct_tests") then
    add_requires("doctest 2.4.11", {system = false})
end

local function ct_common()
    add_defines("NOMINMAX", "WIN32_LEAN_AND_MEAN")
    if is_plat("linux") then
        add_cxflags("-fPIC")
        add_syslinks("pthread")
    end
end

target("crosstransfer_core")
    set_kind("static")
    ct_common()
    -- The API is compiled in this archive, not in native_export.cpp. MSVC
    -- must see dllexport here for the umbrella DLL to expose every Ct* call.
    if is_plat("windows") and has_config("ct_native") then
        add_defines("CT_BUILDING_SHARED")
    end
    add_deps("minirtc")
    add_packages("nlohmann_json", "spdlog", "openssl3")
    add_files("core/src/**.cpp")
    remove_files("core/src/api/native_export.cpp")
    add_includedirs("core/include", {public = true})
    add_includedirs("core/src")
    add_installfiles("core/include/crosstransfer/ct_api.h", {prefixdir = "include/crosstransfer"})
target_end()

if has_config("ct_cli") and not is_plat("iphoneos") then
    target("ct_cli")
        set_kind("binary")
        ct_common()
        add_deps("crosstransfer_core")
        add_packages("nlohmann_json")
        add_files("cli/*.cpp")
    target_end()
end

if has_config("ct_tests") and not is_plat("iphoneos") then
    target("core_tests")
        set_kind("binary")
        set_default(false)
        ct_common()
        add_deps("crosstransfer_core")
        add_packages("nlohmann_json", "spdlog", "openssl3", "doctest")
        add_includedirs("core/src")
        add_files("core/tests/*.cpp")
    target_end()
end

if has_config("ct_native") then
    target("crosstransfer_native")
        set_kind("shared")
        ct_common()
        add_deps("crosstransfer_core", "minirtc")
        add_files("core/src/api/native_export.cpp")
        if is_plat("macosx", "iphoneos") then
            add_ldflags("-Wl,-force_load,$(builddir)/$(plat)/$(arch)/$(mode)/libcrosstransfer_core.a", {force = true})
            add_ldflags("-Wl,-install_name,@rpath/libcrosstransfer_native.dylib", {force = true})
        elseif is_plat("linux", "android") then
            add_ldflags("-Wl,--whole-archive", "$(builddir)/$(plat)/$(arch)/$(mode)/libcrosstransfer_core.a",
                "-Wl,--no-whole-archive", {force = true})
        elseif is_plat("windows") then
            add_defines("CT_BUILDING_SHARED")
            add_shflags("/WHOLEARCHIVE:$(builddir)/$(plat)/$(arch)/$(mode)/crosstransfer_core.lib", {force = true})
        end
    target_end()
end
