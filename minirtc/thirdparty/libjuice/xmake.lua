package("libjuice")
    set_homepage("https://github.com/paullouisageneau/libjuice")
    set_description("libjuice with CrossTransfer's opt-in relay-only candidate policy")
    set_license("MPL-2.0")
    add_urls("https://github.com/paullouisageneau/libjuice/archive/refs/tags/$(version).tar.gz")
    add_versions("v1.7.2", "75159867c4a5a689a6559e11aa0d30c9eba12ce73a4ae3d898b521467e1f635d")
    add_patches("v1.7.2", path.join(os.scriptdir(), "relay-only.patch"),
                "f4da71fead668b403be34828b23d758b3d6da3c67f6005554d00ac255568a31d")
    -- Keep patched and upstream package installations in separate cache entries.
    add_configs("crosstransfer_patch", {description = "MPL source revision", default = "ct1-f4da71fe", type = "string", values = {"ct1-f4da71fe"}, readonly = true})
    add_deps("cmake~host >=3.21 <4.0", {host = true})
    if is_plat("windows", "mingw") then
        add_syslinks("ws2_32", "bcrypt")
    elseif is_plat("linux", "bsd") then
        add_syslinks("pthread")
    end
    on_load(function (package)
        if not package:config("shared") and package:is_plat("windows", "mingw") then
            package:add("defines", "JUICE_STATIC")
        end
    end)
    on_install(function (package)
        -- Nettle is intentionally disabled (LGPL is outside the project's policy).
        local configs = {"-DNO_TESTS=ON", "-DUSE_NETTLE=OFF"}
        table.insert(configs, "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"))
        table.insert(configs, "-DBUILD_SHARED_LIBS=" .. (package:config("shared") and "ON" or "OFF"))
        import("package.tools.cmake").install(package, configs)
    end)
    on_test(function (package)
        assert(package:has_cfuncs("juice_create", {includes = "juice/juice.h"}))
        assert(package:check_csnippets({test = [[
            void test(void) { juice_config_t c = {0}; c.relay_only = true; }
        ]]}, {includes = "juice/juice.h"}))
    end)
