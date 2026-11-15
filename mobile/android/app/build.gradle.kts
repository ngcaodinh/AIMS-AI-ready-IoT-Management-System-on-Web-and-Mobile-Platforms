plugins {
    id("com.android.application")
    // Flutter plugin chạy sau Android plugin để nhận đúng cấu hình target của SDK đã pin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.nexa.nexa_iot"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // ID riêng cho client Nexa của dự án; không dùng applicationId làm authority cho API.
        applicationId = "dev.nexa.nexa_iot"
        // Candidate24 theo Flutter3.47 support matrix; vẫn cần PoC storage/min OS trước nghiệm thu.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Lấy version từ manifest ứng dụng để APK/test report truy vết cùng code state.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Runner chỉ nằm trong test APK androidTest; app phát hành không chứa thao tác phá khóa PoC.
        testInstrumentationRunner = "dev.nexa.nexa_iot.StorageFaultInstrumentation"
    }

    // PoC chỉ dùng debug build; release không được tự ký bằng debug key của template.
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
