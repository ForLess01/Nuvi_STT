import java.net.URI
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val sherpaVersion = "1.13.4"
val sherpaSha256 = "03f9c4df965f21c71269365a7951a7f23b5696fddd093fa318c80d65550ab780"
val sherpaAar = layout.buildDirectory.file("vendor/sherpa-onnx-$sherpaVersion.aar")
val prepareSherpaOnnx by tasks.registering {
    outputs.file(sherpaAar)
    doLast {
        val destination = sherpaAar.get().asFile
        destination.parentFile.mkdirs()
        if (!destination.isFile) {
            URI("https://github.com/k2-fsa/sherpa-onnx/releases/download/v$sherpaVersion/sherpa-onnx-$sherpaVersion.aar")
                .toURL().openStream().use { input -> destination.outputStream().use(input::copyTo) }
        }
        val actual = MessageDigest.getInstance("SHA-256")
            .digest(destination.readBytes()).joinToString("") { "%02x".format(it) }
        check(actual == sherpaSha256) {
            destination.delete()
            "sherpa-onnx checksum mismatch: expected $sherpaSha256, got $actual"
        }
    }
}

android {
    namespace = "app.nuvi.android"
    compileSdk = 35
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "app.nuvi.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DWHISPER_BUILD_TESTS=OFF",
                    "-DWHISPER_BUILD_EXAMPLES=OFF",
                    "-DWHISPER_BUILD_SERVER=OFF"
                )
                cppFlags += listOf("-std=c++17", "-fexceptions", "-frtti")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    packaging {
        jniLibs.useLegacyPackaging = false
    }
}

dependencies {
    implementation(files(sherpaAar))
    implementation("org.apache.commons:commons-compress:1.27.1")
    implementation("commons-io:commons-io:2.17.0")
    testImplementation("junit:junit:4.13.2")
}

tasks.configureEach {
    if (name == "preBuild" || name.startsWith("compile") && name.endsWith("Kotlin")) {
        dependsOn(prepareSherpaOnnx)
    }
}
