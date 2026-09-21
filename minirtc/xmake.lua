-- MiniRTC (CrossTransfer specialised build): data-only transport engine.
-- ICE via libjuice, DTLS-SRTP via OpenSSL + libsrtp, reliable stream via KCP,
-- signaling over WebSocket (websocketpp + asio). No LGPL dependencies.
set_project("minirtc")
set_version("1.0.0")

add_rules("mode.release", "mode.debug")
set_languages("c++17")
set_encodings("utf-8")

add_defines("ASIO_STANDALONE", "ASIO_HAS_STD_TYPE_TRAITS", "ASIO_HAS_STD_SHARED_PTR",
    "ASIO_HAS_STD_ADDRESSOF", "ASIO_HAS_STD_ATOMIC", "ASIO_HAS_STD_CHRONO",
    "ASIO_HAS_CSTDINT", "ASIO_HAS_STD_ARRAY", "ASIO_HAS_STD_SYSTEM_ERROR",
    "NOMINMAX", "WIN32_LEAN_AND_MEAN")

includes("thirdparty")

add_requires("asio 1.32.0", "nlohmann_json 3.11.3", "spdlog 1.14.1",
    "websocketpp 0.8.2", "libsrtp v2.7.0", "kcp 1.7",
    "libjuice v1.7.2", "miniupnpc 2.3.3",
    {system = false, configs = {shared = false}})
add_requireconfs("libsrtp.openssl3", {version = "3.3.2", override = true, configs = {shared = false}})
add_packages("asio", "nlohmann_json", "spdlog", "websocketpp", "libsrtp", "kcp",
    "libjuice", "miniupnpc")

if is_plat("windows") then
    add_defines("_WEBSOCKETPP_CPP11_INTERNAL_")
    set_runtimes("MT")
elseif is_plat("linux") then
    add_cxflags("-fPIC", "-Wno-unused-variable")
    add_syslinks("pthread")
elseif is_plat("macosx", "iphoneos") then
    add_cxflags("-Wno-unused-variable")
    add_frameworks("Security", "Foundation", "SystemConfiguration", "CoreFoundation")
end

option("minirtc_examples")
    set_default(true)
    set_showmenu(true)
    set_description("Build minirtc examples (data_echo)")
option_end()

target("minirtc")
    set_kind("static")
    add_files("src/log/*.cpp",
        "src/common/common.cpp",
        "src/common/clock/*.cpp",
        "src/common/rtc_base/*.cc",
        "src/common/rtc_base/network/*.cc",
        "src/common/rtc_base/numerics/*.cc",
        "src/common/api/units/*.cc",
        "src/common/api/transport/*.cc",
        "src/common/api/clock/*.cc",
        "src/common/api/ntp/*.cc",
        "src/thread/*.cpp",
        "src/rtp/rtp_packet/*.cpp",
        "src/rtp/rtp_packetizer/*.cpp",
        "src/rtcp/*.cpp",
        "src/rtcp/rtcp_packet/*.cpp",
        "src/rtcp/rtp_feedback/*.cpp",
        "src/qos/*.cc",
        "src/qos/*.cpp",
        "src/srtp/*.cpp",
        "src/ws/*.cpp",
        "src/ice/*.cpp",
        "src/transport/paced_sender/*.cpp",
        "src/transport/*.cpp",
        "src/pc/*.cpp",
        "src/api/*.cpp")
    if not is_plat("windows") then
        remove_files("src/common/rtc_base/win32.cc")
    end
    add_includedirs("src/api", {public = true})
    add_includedirs("src/log", "src/common", "src/thread",
        "src/rtp/rtp_packet", "src/rtp/rtp_packetizer",
        "src/rtcp", "src/rtcp/rtcp_packet", "src/rtcp/rtp_feedback",
        "src/qos", "src/srtp", "src/ws", "src/ice",
        "src/transport", "src/transport/paced_sender", "src/pc")
    if is_plat("windows") then
        add_syslinks("Shell32", "Advapi32", "Dnsapi", "Shlwapi", "Crypt32",
            "ws2_32", "User32", "Secur32", "Bcrypt", "iphlpapi", "winmm")
    end
    add_installfiles("src/api/minirtc.h", {prefixdir = "include"})

if has_config("minirtc_examples") and not is_plat("iphoneos") then
    target("data_echo")
        set_kind("binary")
        add_deps("minirtc")
        add_files("examples/data_echo/main.cpp")
end
