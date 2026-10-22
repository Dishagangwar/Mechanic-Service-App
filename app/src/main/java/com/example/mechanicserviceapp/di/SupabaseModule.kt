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
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.postgrest
import io.ktor.client.engine.okhttp.OkHttp
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object SupabaseModule {

    /**
     * Only ever built when [SupabaseConfig.isConfigured]; every repository injects
     * its plugin through a [dagger.Lazy] and checks the flag first, so an
     * unconfigured build never reaches the client at all.
     */
    @Provides
    @Singleton
    fun provideSupabaseClient(): SupabaseClient = createSupabaseClient(
        supabaseUrl = SupabaseConfig.url,
        supabaseKey = SupabaseConfig.anonKey
    ) {
        install(Auth) {
            // The Android artifact registers an androidx.startup initializer that hands
            // Supabase an application context, so the session is persisted and restored
            // on next launch without any work here.
            autoLoadFromStorage = true
            alwaysAutoRefresh = true
        }
        // PostgREST is the data API: tables, views and the nearby_mechanics RPC. Every
        // request carries the signed-in user's JWT, which is what the row level security
        // policies in supabase/migrations/0003_rls.sql are written against.
        install(Postgrest)
        // Edge Functions. Only `nearby-import` is called, and only to pull in a region
        // the backend has not seen before.
        install(Functions)

        httpEngine = OkHttp.create()
    }

    @Provides
    @Singleton
    fun provideAuth(client: SupabaseClient): Auth = client.auth

    @Provides
    @Singleton
    fun providePostgrest(client: SupabaseClient): Postgrest = client.postgrest

    @Provides
    @Singleton
    fun provideFunctions(client: SupabaseClient): Functions = client.functions
}
