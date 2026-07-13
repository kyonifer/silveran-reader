import com.android.ide.common.vectordrawable.Svg2Vector
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction

plugins {
    id("com.android.application") version "8.11.1"
    id("org.jetbrains.kotlin.android") version "2.2.0"
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.0"
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

    buildFeatures {
        compose = true
    }

    sourceSets {
        getByName("main") {
            java.srcDirs(
                // jextract-generated bindings for the SilveranAndroidBridge Swift module
                "../swift/.build/plugins/outputs/swift/SilveranAndroidBridge/destination/JExtractSwiftPlugin/src/generated/java",
            )
        }
    }
}

abstract class GenerateReadaloudVector : DefaultTask() {
    @get:InputFile
    abstract val sourceFile: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun generate() {
        val output = outputDirectory.file("drawable/ic_readaloud.xml").get().asFile
        output.parentFile.mkdirs()
        output.outputStream().use { stream ->
            val errors = Svg2Vector.parseSvgToXml(sourceFile.get().asFile.toPath(), stream)
            check(errors.isBlank()) { errors }
        }
    }
}

val generateReadaloudVector = tasks.register<GenerateReadaloudVector>("generateReadaloudVector") {
    sourceFile.set(
        rootProject.layout.projectDirectory.file(
            "../XCodeApps/Assets.xcassets/readalong.imageset/readaloud.svg"
        )
    )
}

androidComponents {
    onVariants { variant ->
        variant.sources.res?.addGeneratedSourceDirectory(
            generateReadaloudVector,
            GenerateReadaloudVector::outputDirectory,
        )
    }
}

dependencies {
    // swift-java's Java runtime (org.swift.swiftkit.core), built from the
    // resolved swift-java checkout by scripts/androidbuild. Consumed as a jar
    // because its sources reference jdk.jfr, which android.jar lacks.
    implementation(files("libs/swiftkit-core.jar"))
    implementation(platform("androidx.compose:compose-bom:2025.06.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.9.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
