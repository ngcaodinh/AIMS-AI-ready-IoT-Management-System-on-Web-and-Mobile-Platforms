/** Nối Flutter SDK do công cụ cấu hình với Gradle; source không chứa credential hoặc SDK secret. */
pluginManagement {
    val flutterSdkPath =
        /** Đọc vị trí SDK từ interface cấu hình Gradle khi build, không hardcode đường dẫn máy cá nhân. */
        run {
            val properties = java.util.Properties()
            /** Tự đóng stream sau khi lấy metadata để tránh giữ file lock trên Windows. */
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            // Thiếu SDK phải dừng cấu hình; không dò credential hoặc environment làm fallback.
            if (flutterSdkPath == null) error("flutter.sdk not set in local.properties")
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
