-- CrossTransfer: root build.
--   minirtc              specialised data-only transport engine (static)
--   crosstransfer_core   share / receive state machines, block protocol, C API (static)
--   ct_cli               command line client (binary)
--   core_tests           unit tests (binary, doctest)
--   crosstransfer_native Flutter FFI umbrella (desktop shared / iOS static)
set_project("crosstransfer")
set_version("0.1.0")

add_rules("mode.release", "mode.debug")
set_languages("c++17")
set_encodings("utf-8")

if is_plat("iphoneos") then
    -- xmake 3.1 package hashes omit appledev. Make the target triple part of
    -- package configuration so arm64 simulator cannot reuse device archives.
    local triple = get_config("arch") .. "-apple-ios" .. (get_config("target_minver") or "15.0")
    if get_config("appledev") == "simulator" then
        triple = triple .. "-simulator"
    end
    add_requireconfs("**", {configs = {cxflags = "--target=" .. triple}})
end

-- Match Flutter's Windows CRT and propagate it to all native dependencies.
if is_plat("windows") then
    set_runtimes(is_mode("debug") and "MDd" or "MD")
end

-- macOS deployment floor for the Flutter app is 12.0 (see app/macos/Podfile);
-- pass `--target_minver=12.0` at configure time (tools/build_native.sh does).

includes("minirtc")

add_requires("nlohmann_json 3.11.3", "spdlog 1.14.1",
    {system = false, configs = {shared = false}})
add_requires("openssl3 3.5.8", {system = false, configs = {shared = false}})

option("ct_cli")
    set_default(true)
    set_showmenu(true)
    set_description("Build the ct_cli command line client")
option_end()

option("ct_developer")
    set_default(false)
    set_showmenu(true)
    set_description("Internal development only: allow runtime service overrides; never distribute")
option_end()

option("ct_service_host")
    set_default("")
    set_showmenu(true)
    set_description("Publisher-managed WSS service hostname (required for commercial builds)")
option_end()

option("ct_link_host")
    set_default("")
    set_showmenu(true)
    set_description("Publisher-managed HTTPS share-link hostname (optional)")
option_end()

option("ct_tests")
    set_default(true)
    set_showmenu(true)
    set_description("Build core unit tests (doctest)")
option_end()

option("ct_native")
    set_default(false)
    set_showmenu(true)
    set_description("Build the crosstransfer_native FFI library (iOS static, desktop shared)")
option_end()

if has_config("ct_tests") then
    add_requires("doctest 2.4.11", {system = false})
end

local function ct_common()
    add_defines("NOMINMAX", "WIN32_LEAN_AND_MEAN")
    if is_plat("linux", "android") then
        add_cxflags("-fPIC")
    end
    if is_plat("linux") then
        add_syslinks("pthread")
    end
end

target("crosstransfer_core")
    set_kind("static")
    ct_common()
    on_load(function (target)
        local developer = has_config("ct_developer")
        local host = get_config("ct_service_host") or ""
        local link_host = get_config("ct_link_host") or ""
        local function valid_host(value)
            if #value > 253 or value:find("..", 1, true) or value:sub(-1) == "." then return false end
            for label in value:gmatch("[^.]+") do
                if #label > 63 or not label:match("^[%w][%w%-]*$")
                    or not label:sub(-1):match("[%w]") then return false end
            end
            return value:match("^[%w]") ~= nil
        end
        assert(developer or host ~= "",
            "Commercial builds require --ct_service_host=<hostname>. Internal tests must explicitly use --ct_developer=y.")
        assert(host == "" or valid_host(host), "ct_service_host must be a hostname without scheme, port or path")
        assert(link_host == "" or valid_host(link_host), "ct_link_host must be a hostname without scheme, port or path")
        target:add("defines", "CT_DEVELOPER_MODE=" .. (developer and "1" or "0"), {public = true})
        target:add("defines", 'CT_SERVICE_HOST="' .. host .. '"', 'CT_LINK_HOST="' .. link_host .. '"')
    end)
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
        add_packages("nlohmann_json", "spdlog", "openssl3", "doctest", "asio", "libjuice")
        add_includedirs("core/src")
        add_files("core/tests/*.cpp")
    target_end()
end

if has_config("ct_native") then
    target("crosstransfer_native")
        if is_plat("iphoneos") then
            set_kind("static")
            -- Include core, MiniRTC and their static packages in one archive.
            set_policy("build.merge_archive", true)
            -- libsrtp's package already carries its OpenSSL archives.
            add_packages("spdlog", "libsrtp", "kcp", "libjuice", "miniupnpc")
        else
            set_kind("shared")
        end
        ct_common()
        add_deps("crosstransfer_core", "minirtc")
        add_files("core/src/api/native_export.cpp")
        if is_plat("macosx") then
            add_ldflags("-Wl,-force_load,$(builddir)/$(plat)/$(arch)/$(mode)/libcrosstransfer_core.a", {force = true})
            add_ldflags("-Wl,-install_name,@rpath/libcrosstransfer_native.dylib", {force = true})
        elseif is_plat("linux", "android") then
            add_ldflags("-Wl,--whole-archive", "$(builddir)/$(plat)/$(arch)/$(mode)/libcrosstransfer_core.a",
                "-Wl,--no-whole-archive", {force = true})
            if is_plat("android") then
                add_shflags("-Wl,-z,max-page-size=16384", {force = true})
                -- OpenSSL's ARM assembly uses local-relative capability data.
                -- Keep its static symbols private to this umbrella library.
                add_shflags("-Wl,--exclude-libs,libcrypto.a:libssl.a", {force = true})
            end
        elseif is_plat("windows") then
            add_defines("CT_BUILDING_SHARED")
            add_shflags("/WHOLEARCHIVE:$(builddir)/$(plat)/$(arch)/$(mode)/crosstransfer_core.lib", {force = true})
        end
    target_end()
end
