package("miniupnpc")
    set_homepage("https://miniupnp.tuxfamily.org/")
    set_description("UPnP IGD client lightweight library")
    set_license("BSD-3-Clause")

    add_urls("https://github.com/miniupnp/miniupnp/archive/refs/tags/miniupnpc_$(version).tar.gz", {version = function (version)
        return (version:gsub("%.", "_"))
    end})
    add_versions("2.3.3", "8cf2c833b3e76fc4893ff29c2a376e3394962449e5970e373c0a91421724d222")

    if is_plat("windows", "mingw") then
        add_syslinks("ws2_32", "iphlpapi")
        add_defines("MINIUPNP_STATICLIB")
    end

    add_deps("cmake")

    on_install(function (package)
        os.cd("miniupnpc")
        local configs = {
            "-DUPNPC_BUILD_TESTS=OFF",
            "-DUPNPC_BUILD_SAMPLE=OFF",
        }
        table.insert(configs, "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"))
        table.insert(configs, "-DUPNPC_BUILD_SHARED=" .. (package:config("shared") and "ON" or "OFF"))
        table.insert(configs, "-DUPNPC_BUILD_STATIC=" .. (package:config("shared") and "OFF" or "ON"))
        import("package.tools.cmake").install(package, configs)
    end)

    on_test(function (package)
        assert(package:has_cfuncs("upnpDiscover", {includes = "miniupnpc/miniupnpc.h"}))
    end)
