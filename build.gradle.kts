import org.koin.compiler.plugin.KoinGradleExtension

plugins {
    id("dev.dimension.flare.root-conventions")
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.ksp) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.ktorfit) apply false
    alias(libs.plugins.skie) apply false
    alias(libs.plugins.ben.manes.versions)
    alias(libs.plugins.compose.compiler) apply false
    alias(libs.plugins.room) apply false
    alias(libs.plugins.composeMultiplatform) apply false
    alias(libs.plugins.nucleus) apply false
    alias(libs.plugins.koin.compiler) apply false
}

subprojects {
    // Kotlin/Native 2.4.20 在给 cryptography-provider-cryptokit 生成 CryptoKitAesGcm 的 itable
    // 时会触发编译器 ICE（no implementation found for AES.keyDecoder），只在 iphoneos 的 Release
    // 链接阶段出现，直接导致 IPA 打不出来。本项目只用到 SHA-256，cryptography-provider-apple
    // （CommonCrypto）已覆盖，所以全局排除 cryptokit。
    configurations.configureEach {
        exclude(group = "dev.whyoleg.cryptography", module = "cryptography-provider-cryptokit")
    }

    pluginManager.withPlugin("io.insert-koin.compiler.plugin") {
        extensions.configure<KoinGradleExtension> {
            logSeverity.set("info")
            versionCheckSeverity.set("info")
        }
    }
}
