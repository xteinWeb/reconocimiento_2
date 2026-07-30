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

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    val extension = extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
    if (extension != null) {
        extension.compileSdkVersion(36)
        extension.defaultConfig.targetSdkVersion(36)
    } else {
        afterEvaluate {
            val ext = extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
            ext?.compileSdkVersion(36)
            ext?.defaultConfig?.targetSdkVersion(36)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
