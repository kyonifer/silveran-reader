plugins {
    id("com.android.application") version "8.11.1"
    id("org.jetbrains.kotlin.android") version "2.2.0"
}

android {
    namespace = "com.kyonifer.silveran"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.kyonifer.silveran"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            java.srcDirs(
                // jextract-generated bindings for the SilveranAndroidCore Swift module
                "../swift/.build/plugins/outputs/swift/SilveranAndroidCore/destination/JExtractSwiftPlugin/src/generated/java",
            )
        }
    }
}

dependencies {
    // swift-java's Java runtime (org.swift.swiftkit.core), built from the
    // resolved swift-java checkout by scripts/androidbuild. Consumed as a jar
    // because its sources reference jdk.jfr, which android.jar lacks.
    implementation(files("libs/swiftkit-core.jar"))
}
