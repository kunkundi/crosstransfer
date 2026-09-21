plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingValues = listOf("CT_ANDROID_KEYSTORE", "CT_ANDROID_KEY_ALIAS", "CT_ANDROID_STORE_PASSWORD", "CT_ANDROID_KEY_PASSWORD")
    .associateWith { providers.environmentVariable(it).orNull }
val productionSigning = signingValues.values.any { !it.isNullOrBlank() }
if (productionSigning) {
    check(signingValues.values.all { !it.isNullOrBlank() }) { "All four CT_ANDROID signing variables are required" }
}

android {
    namespace = "com.crosstransfer.crosstransfer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.crosstransfer.crosstransfer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += setOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    signingConfigs {
        if (productionSigning) create("production") {
            storeFile = file(signingValues.getValue("CT_ANDROID_KEYSTORE")!!)
            keyAlias = signingValues.getValue("CT_ANDROID_KEY_ALIAS")
            storePassword = signingValues.getValue("CT_ANDROID_STORE_PASSWORD")
            keyPassword = signingValues.getValue("CT_ANDROID_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            // CI/local release APKs are test artifacts; real distribution requires
            // the owner's key and matching App Link certificate association.
            signingConfig = signingConfigs.getByName(if (productionSigning) "production" else "debug")
        }
    }

    packaging { jniLibs { useLegacyPackaging = false } }
}

dependencies {
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    // integration_test brings older runner APIs into the debug APK. Keep the
    // app/test configurations consistent under AGP 9 dependency resolution.
    debugImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.test.ext:junit:1.3.0")
}

// xmake is the single source of truth for the C++ build, matching desktop/iOS.
// Fail early if the per-ABI artifacts were not built before a Gradle invocation.
val verifyNativeLibraries by tasks.registering {
    doLast {
        val requested = providers.gradleProperty("target-platform").orNull
        val abis = requested?.split(',')?.map { when (it) {
            "android-arm" -> "armeabi-v7a"
            "android-arm64" -> "arm64-v8a"
            "android-x64" -> "x86_64"
            else -> error("Unsupported Flutter Android target: $it")
        } } ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        abis.forEach { abi ->
            check(file("src/main/jniLibs/$abi/libcrosstransfer_native.so").isFile) {
                "Missing native engine for $abi. Run tools/build_android_native.sh first."
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(verifyNativeLibraries) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Freeze the audited runtime graph, including transitive artifacts. This does
// not treat the build tool's own dependencies as app runtime libraries.
tasks.register("verifyRuntimeLicenses") {
    doLast {
        val modules = configurations.getByName("releaseRuntimeClasspath").incoming
            .resolutionResult.allComponents.mapNotNull { component ->
                (component.id as? org.gradle.api.artifacts.component.ModuleComponentIdentifier)?.let {
                    "${it.group}:${it.module}:${it.version}"
                }
            }.sorted()
        val report = layout.buildDirectory.file("reports/runtime-modules.txt").get().asFile
        report.parentFile.mkdirs()
        report.writeText(modules.joinToString("\n", postfix = "\n"))
        val audited = rootProject.file("../../docs/licenses/android-runtime-modules.txt")
        check(audited.isFile && audited.readLines().filter { it.isNotBlank() } == modules) {
            "Android runtime dependencies changed; review licenses and update the inventory. Resolved graph: $report"
        }
        check(modules.none { it.contains("desugar_jdk_libs") || it.contains("mlkit") || it.contains("play-services") }) {
            "A removed dependency was reintroduced into the app runtime"
        }
        check(configurations.getByName("coreLibraryDesugaring").allDependencies.isEmpty()) {
            "Core-library desugaring has not been approved by the project's license policy"
        }
    }
}
