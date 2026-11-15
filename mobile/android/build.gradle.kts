/** Dùng repository chính thức cho mọi module Android của scaffold, không thêm mirror tùy ý. */
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

/** Gom output từng module dưới build của ứng dụng để clean không chạm source hoặc SDK. */
subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
/** Cấu hình module app trước plugin con để Flutter nhận cùng cấu hình Android. */
subprojects {
    project.evaluationDependsOn(":app")
}

/** Chỉ dọn output do Gradle quản lý; không xóa fixture, source hoặc bộ nhớ ứng dụng. */
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
