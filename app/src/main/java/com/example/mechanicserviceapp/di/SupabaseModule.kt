package com.example.mechanicserviceapp.di

import com.example.mechanicserviceapp.util.SupabaseConfig
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.createSupabaseClient
import io.ktor.client.engine.okhttp.OkHttp
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object SupabaseModule {

    /**
     * Only ever built when [SupabaseConfig.isConfigured]; the repository injects this
     * through a [dagger.Lazy] and checks the flag first, so an unconfigured build never
     * reaches the client at all.
     */
    @Provides
    @Singleton
    fun provideSupabaseClient(): SupabaseClient = createSupabaseClient(
        supabaseUrl = SupabaseConfig.url,
        supabaseKey = SupabaseConfig.anonKey
    ) {
        install(Auth) {
            // The Android artifact registers an androidx.startup initializer that hands
            // Supabase an application context, so the session is persisted and restored on
            // next launch without any work here.
            autoLoadFromStorage = true
            alwaysAutoRefresh = true
        }
        // supabase-kt speaks Ktor rather than Retrofit; OkHttp is already on the classpath
        // for the mechanics feed, so reuse that engine.
        httpEngine = OkHttp.create()
    }

    /**
     * The auth plugin is what the repository actually talks to. Exposing it directly keeps
     * the Supabase client out of the data layer's constructor signatures.
     */
    @Provides
    @Singleton
    fun provideAuth(client: SupabaseClient): Auth = client.auth
}
