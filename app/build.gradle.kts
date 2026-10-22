import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

// Supabase credentials live in local.properties (git-ignored) so they never land in a commit.
// CI has no local.properties, so fall back to environment variables there.
val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

fun secret(key: String): String =
    localProperties.getProperty(key)
        ?: System.getenv(key)
        ?: ""

android {
    namespace = "com.example.mechanicserviceapp"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "com.example.mechanicserviceapp"
        minSdk = 24
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Supabase project credentials. Set SUPABASE_URL and SUPABASE_ANON_KEY in
        // local.properties; both are safe to ship in the APK (the anon key is the public
        // client key and is governed by row level security on the server).
        buildConfigField("String", "SUPABASE_URL", "\"${secret("SUPABASE_URL")}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${secret("SUPABASE_ANON_KEY")}\"")
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    buildTypes {
        release {
            optimization {
                enable = false
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

dependencies {
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.constraintlayout)
    implementation(libs.androidx.core.ktx)
    implementation(libs.material)

    // UI
    implementation(libs.androidx.fragment.ktx)
    implementation(libs.androidx.recyclerview)
    implementation(libs.androidx.swiperefreshlayout)

    // Architecture components
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.navigation.fragment.ktx)
    implementation(libs.androidx.navigation.ui.ktx)
    implementation(libs.kotlinx.coroutines.android)

    // Backend: Supabase auth, PostgREST data access, and Edge Function invocation.
    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.supabase.postgrest)
    implementation(libs.supabase.functions)
    implementation(libs.ktor.client.okhttp)

    // Location, for searching around where the user actually is.
    implementation(libs.play.services.location)

    // Dependency injection
    implementation(libs.hilt.android)
    implementation(libs.androidx.hilt.navigation.fragment)
    ksp(libs.hilt.compiler)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.rules)
    // The location tests drive the real FusedLocationProviderClient, so they need
    // its mock-location API and the Task -> coroutine bridge.
    androidTestImplementation(libs.play.services.location)
    androidTestImplementation(libs.kotlinx.coroutines.play.services)
}
