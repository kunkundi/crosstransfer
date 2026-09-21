-- Local override of xmake-repo's openssl3 (Apache-2.0): explicit Configure
-- target on macOS and the requested Windows CRT. Keep in sync when bumping.
package("openssl3")
    set_homepage("https://www.openssl.org/")
    set_description("A robust, commercial-grade, and full-featured toolkit for TLS and SSL.")
    set_license("Apache-2.0")

    -- Pin the maintained 3.5 LTS release and its official release-asset SHA-256.
    add_urls("https://github.com/openssl/openssl/releases/download/openssl-$(version)/openssl-$(version).tar.gz")
    add_versions("3.5.8", "a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2")

    on_fetch("fetch")

    -- https://security.stackexchange.com/questions/173425/how-do-i-calculate-md2-hash-with-openssl
    add_configs("md2", {description = "Enable MD2 on OpenSSl3 or not", default = false, type = "boolean"})
    add_configs("multi-threading", {description = "Enable multi-threading support.", default = true, type = "boolean"})

    if is_plat("wasm") then
        add_configs("shared", {description = "Build shared library.", default = false, type = "boolean", readonly = true})
    end

    -- @see https://github.com/xmake-io/xmake-repo/pull/7797#issuecomment-3153471643
    if is_plat("windows") then
        add_configs("jom", {description = "Try using jom to compile in parallel.", default = false, type = "boolean"})
    end

    on_load(function (package)
        if not package:is_precompiled() then
            if package:is_plat("windows") then
                package:add("deps", "nasm")
                -- the perl executable found in GitForWindows will fail to build OpenSSL
                -- see https://github.com/openssl/openssl/blob/master/NOTES-PERL.md#perl-on-windows
                package:add("deps", "strawberry-perl", {system = false})
                if package:config("jom") then
                    -- check xmake tool jom
                    import("package.tools.jom", {try = true})
                    if jom then
                        package:add("deps", "jom", {private = true})
                    end
                end
            elseif package:is_plat("android", "wasm") and is_host("windows") and os.arch() == "x64" then
                -- when building for android on windows, use msys2 perl instead of strawberry-perl to avoid configure issue
                package:add("deps", "msys2", {configs = {msystem = "MINGW64", base_devel = true}, private = true})
            end
        end

        -- @note we must use package:is_plat() instead of is_plat in description for supporting add_deps("openssl", {host = true}) in python
        if package:is_plat("windows") then
            package:add("links", "libssl", "libcrypto")
        else
            package:add("links", "ssl", "crypto")
        end
        if package:is_plat("windows", "mingw", "msys") then
            package:add("syslinks", "ws2_32", "user32", "crypt32", "advapi32")
        elseif package:is_plat("linux", "bsd", "cross") then
            package:add("syslinks", "dl")
            if (package:config("multi-threading")) then
                package:add("syslinks", "pthread")
            end
        end
        if package:is_plat("linux") then
            package:add("extsources", "apt::libssl-dev")
        end
    end)

    on_install("windows", function (package)
        import("package.tools.jom", {try = true})
        import("package.tools.nmake")
        local configs = {"Configure", "no-tests"}
        local target
        if package:is_arch("x86", "i386") then
            target = "VC-WIN32"
        elseif package:is_arch("arm64") then
            target = "VC-WIN64-ARM"
        elseif package:is_arch("arm.*") then
            target = "VC-WIN32-ARM"
        else
            target = "VC-WIN64A"
        end
        table.insert(configs, target)
        table.insert(configs, package:config("shared") and "shared" or "no-shared")
        table.insert(configs, "--prefix=" .. package:installdir())
        table.insert(configs, "--openssldir=" .. package:installdir())

        if package:config("md2") then
            table.insert(configs, "enable-md2")
        end
        table.insert(configs, package:config("multi-threading") and "threads" or "no-threads")

        if package:config("jom") and jom then
            table.insert(configs, "no-makedepend")
        end

        if package:is_debug() then
            table.insert(configs, "/FS")
        else
            io.replace("Configurations/10-main.conf", "/debug", "", {plain = true})
            io.replace("Configurations/10-main.conf", "/Zi", "", {plain = true})
            io.replace("Configurations/50-masm.conf", "/Zi", "", {plain = true})
            if package:version():ge("3.1") then
                io.replace("Configurations/50-win-clang-cl.conf", "/Zi", "", {plain = true})
            end
            io.replace("util/copy.pl", "if (-d $dest)", "if (! -e $_) { next; }\n\tif (-d $dest)", {plain = true})
        end

        -- OpenSSL's no-shared target hardcodes /MT even when the consuming
        -- package requests /MD. Keep its static archives on the same CRT as
        -- the other dependencies and the Flutter FFI DLL.
        if package:has_runtime("MD", "MDd") then
            io.replace("Configurations/10-main.conf", "/MT", "/MD", {plain = true})
            -- no-shared leaves provider cflags without a CRT switch. MSVC then
            -- defaults to /MT while libcrypto references /MD's UCRT imports.
            -- Apply the requested runtime to providers and applications too.
            table.insert(configs, package:has_runtime("MDd") and "/MDd" or "/MD")
        end
        if package:is_debug() or package:has_runtime("MDd", "MTd") then
            table.insert(configs, "--debug")
            local runtime = package:has_runtime("MDd") and "MDd" or "MTd"
            io.replace("Configurations/10-main.conf", '"/MD /Zl"', '"/' .. runtime .. ' /Zl"', {plain = true})
            io.replace("Configurations/10-main.conf", '"/MT /Zl"', '"/' .. runtime .. ' /Zl"', {plain = true})
        end

        os.vrunv("perl", configs)

        if package:config("jom") and jom then
            jom.build(package)
            jom.make(package, {"install_sw"})
        else
            nmake.build(package)
            nmake.make(package, {"install_sw"})
        end
    end)

    on_install("mingw", "msys", function (package)
        local configs = {"Configure", "--libdir=lib", "no-tests"}
        table.insert(configs, package:is_arch("i386", "x86") and "mingw" or "mingw64")
        table.insert(configs, package:config("shared") and "shared" or "no-shared")
        local installdir = package:installdir()
        -- Use MSYS2 paths instead of Windows paths
        if is_subhost("msys") then
            installdir = installdir:gsub("(%a):[/\\](.+)", "/%1/%2"):gsub("\\", "/")
        end
        table.insert(configs, "--prefix=" .. installdir)
        table.insert(configs, "--openssldir=" .. installdir)

        if package:config("md2") then
            table.insert(configs, "enable-md2")
        end
        table.insert(configs, package:config("multi-threading") and "threads" or "no-threads")

        local buildenvs = import("package.tools.autoconf").buildenvs(package)
        buildenvs.RC = package:build_getenv("mrc")
        if is_subhost("msys") then
            local rc = buildenvs.RC
            if rc then
                rc = rc:gsub("(%a):[/\\](.+)", "/%1/%2"):gsub("\\", "/")
                buildenvs.RC = rc
            end
        end
        -- fix 'cp: directory fuzz does not exist'
        if package:config("shared") then
            os.mkdir("fuzz")
        end
        os.vrunv("perl", configs, {envs = buildenvs})
        import("package.tools.make").build(package)
        import("package.tools.make").make(package, {"install_sw"})
    end)

    on_install("macosx", "bsd", function (package)
        -- https://wiki.openssl.org/index.php/Compilation_and_Installation#PREFIX_and_OPENSSLDIR
        local buildenvs = import("package.tools.autoconf").buildenvs(package)
        local configs = {"--openssldir=" .. package:installdir(),
                         "--libdir=lib",
                         "--prefix=" .. package:installdir()}
        table.insert(configs, package:config("shared") and "shared" or "no-shared")
        if package:debug() then
            table.insert(configs, "--debug")
        end

        if package:config("md2") then
            table.insert(configs, "enable-md2")
        end
        table.insert(configs, package:config("multi-threading") and "threads" or "no-threads")

        -- CrossTransfer: `./config` guesses the target from the host CPU, which
        -- breaks arm64 -> x86_64 (and vice versa) cross builds on macOS. Name
        -- the target explicitly instead.
        if package:is_plat("macosx") then
            local target = package:is_arch("arm64") and "darwin64-arm64-cc" or "darwin64-x86_64-cc"
            os.vrunv("./Configure", table.join({target}, configs), {envs = buildenvs})
        else
            os.vrunv("./config", configs, {envs = buildenvs})
        end
        local makeconfigs = {CFLAGS = buildenvs.CFLAGS, ASFLAGS = buildenvs.ASFLAGS}
        import("package.tools.make").build(package, makeconfigs)
        import("package.tools.make").make(package, {"install_sw"})
        if package:config("shared") then
            os.tryrm(path.join(package:installdir("lib"), "*.a"))
        end
    end)

    on_install("linux", "cross", "android", "iphoneos", "wasm", "harmony", function (package)
        local target_arch = "generic32"
        if package:is_arch("x86_64") then
            target_arch = "x86_64"
        elseif package:is_arch("i386", "x86") then
            target_arch = "x86"
        elseif package:is_arch("arm64", "arm64-v8a") then
            target_arch = "aarch64"
        elseif package:is_arch("arm.*") then
            target_arch = "armv4"
        elseif package:is_arch(".*64") then
            target_arch = "generic64"
        end

        local target_plat = "linux"
        if package:is_plat("macosx") then
            target_plat = "darwin64"
            target_arch = "x86_64-cc"
        elseif package:is_plat("harmony") then
            target_plat = "ohos"
            if package:is_arch("arm64", "arm64-v8a") then
                target_arch = "aarch64"
            elseif package:is_arch("arm.*") then
                target_arch = "arm"
            end
        elseif package:is_plat("iphoneos") then
            local xcode = package:toolchain("xcode")
            local simulator = xcode and xcode:config("appledev") == "simulator"
            if simulator then
                target_plat = "iossimulator"
                target_arch = "xcrun"
            else
                if package:is_arch("arm64", "x86_64") then
                    target_plat = "ios64"
                else
                    target_plat = "ios"
                end
                target_arch = "cross"
            end
        end

        local target = target_plat .. "-" .. target_arch
        local configs = {target,
                         package:config("shared") and "shared" or "no-shared",
                         "--libdir=lib",
                         "--openssldir=" .. package:installdir():gsub("\\", "/"),
                         "--prefix=" .. package:installdir():gsub("\\", "/")}

        if package:config("md2") then
            table.insert(configs, "enable-md2")
        end
        table.insert(configs, package:config("multi-threading") and "threads" or "no-threads")

        if package:is_plat("wasm") then
            -- @see https://github.com/openssl/openssl/issues/12174
            table.insert(configs, "no-afalgeng")
        end

        import("configure.patch")(package)
        local buildenvs = import("package.tools.autoconf").buildenvs(package)
        if package:is_plat("android") then
            -- Configure otherwise picks the host ranlib. Apple's ranlib
            -- rewrites the ELF archive index as Mach-O and breaks NDK linking.
            buildenvs.RANLIB = path.join(path.directory(buildenvs.AR), is_host("windows") and "llvm-ranlib.exe" or "llvm-ranlib")
            table.insert(configs, "no-tests")
        end
        if (package:is_plat("android") and is_host("windows")) or
            package:is_plat("wasm") then

            buildenvs.CFLAGS = buildenvs.CFLAGS:gsub("\\", "/")
            buildenvs.CXXFLAGS = buildenvs.CXXFLAGS:gsub("\\", "/")
            buildenvs.CPPFLAGS = buildenvs.CPPFLAGS:gsub("\\", "/")
            buildenvs.ASFLAGS = buildenvs.ASFLAGS:gsub("\\", "/")
            os.vrunv("perl", table.join("./Configure", configs), {envs = buildenvs})
        else
            os.vrunv("./Configure", configs, {envs = buildenvs})
        end

        if is_host("windows") and package:is_plat("wasm") then
            io.replace("Makefile", "bat.exe", "bat", {plain = true})
        end
        local makeconfigs = {CFLAGS = buildenvs.CFLAGS, ASFLAGS = buildenvs.ASFLAGS}
        import("package.tools.make").build(package, makeconfigs)
        import("package.tools.make").make(package, {"install_sw"})
        if package:config("shared") then
            os.tryrm(path.join(package:installdir("lib"), "*.a"))
        end
    end)

    on_test(function (package)
        assert(package:has_cfuncs("SSL_new", {includes = "openssl/ssl.h"}))
    end)
