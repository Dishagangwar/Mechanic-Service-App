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

        // Base URL for the mechanics feed. Once this project is pushed to a public
        // GitHub repo, point this at your own raw content URL and flip USE_MOCK_API
        // to false to hit the network for real.
        buildConfigField(
            "String",
            "BASE_URL",
            "\"https://raw.githubusercontent.com/your-username/MechanicServiceApp/main/api/\""
        )
        // true  -> OkHttp interceptor serves the bundled assets/mechanics.json
        // false -> real HTTPS request against BASE_URL
        buildConfigField("boolean", "USE_MOCK_API", "true")

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

    // Networking
    implementation(libs.retrofit)
    implementation(libs.retrofit.converter.moshi)
    implementation(libs.okhttp.logging.interceptor)
    implementation(libs.moshi)
    implementation(libs.moshi.kotlin)

    // Authentication
    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.ktor.client.okhttp)

    // Dependency injection
    implementation(libs.hilt.android)
    implementation(libs.androidx.hilt.navigation.fragment)
    ksp(libs.hilt.compiler)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
}
