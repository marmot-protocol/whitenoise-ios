import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct TelemetryBuildConfigTests {

    @Test func defaultsToStagingAndTreatsUnresolvedBuildSettingsAsMissing() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryOTLPEndpoint": "$(WHITENOISE_OTLP_ENDPOINT)",
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [:])

        #expect(config.otlpEndpoint == TelemetryBuildConfig.defaultOtlpEndpoint)
        #expect(config.bearerToken == nil)
        #expect(!config.telemetryCredentialsAvailable)
        #expect(config.deploymentEnvironment == "staging")
        #expect(config.serviceVersion == "1.2.3+45")
    }

    @Test func unresolvedBuildSettingsCanReadTelemetryCredentialsFromEnvironment() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryOTLPEndpoint": "$(WHITENOISE_OTLP_ENDPOINT)",
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "$(WHITENOISE_TELEMETRY_ENVIRONMENT)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "WHITENOISE_OTLP_ENDPOINT": "https://collector.example/v1/metrics",
            "OTLP_TOKEN_WHITENOISE_IOS": "env-token",
            "WHITENOISE_TELEMETRY_ENVIRONMENT": "production"
        ])

        #expect(config.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(config.bearerToken == "env-token")
        #expect(config.telemetryCredentialsAvailable)
        #expect(config.deploymentEnvironment == "production")
    }

    @Test func productionEnvironmentMustBeExplicitlyConfigured() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryOTLPEndpoint": "https://collector.example/v1/metrics",
            "WhiteNoiseTelemetryBearerToken": "secret-token",
            "WhiteNoiseTelemetryEnvironment": "production",
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "9"
        ])

        #expect(config.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(config.bearerToken == "secret-token")
        #expect(config.telemetryCredentialsAvailable)
        #expect(config.deploymentEnvironment == "production")
        #expect(config.serviceVersion == "2.0+9")
    }

    @Test func runtimeConfigCarriesInstallAndIOSResourceFields() {
        let config = TelemetryBuildConfig(
            otlpEndpoint: "https://collector.example/v1/metrics",
            bearerToken: "secret-token",
            auditLogBearerToken: nil,
            deploymentEnvironment: "staging",
            serviceVersion: "2.0+9",
            osVersion: "26.0",
            deviceModelIdentifier: "iPhone99,9"
        )

        let runtime = config.runtimeConfig(installId: "install-a")

        #expect(runtime.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(runtime.authorizationBearerToken == "secret-token")
        #expect(runtime.resource?.serviceVersion == "2.0+9")
        #expect(runtime.resource?.serviceInstanceId == "install-a")
        #expect(runtime.resource?.deploymentEnvironment == "staging")
        #expect(runtime.resource?.tenant == "whitenoise-ios")
        #expect(runtime.resource?.osType == "darwin")
        #expect(runtime.resource?.osVersion == "26.0")
        #expect(runtime.resource?.deviceModelIdentifier == "iPhone99,9")
    }

    @Test func supportedDeploymentEnvironmentsPassThrough() {
        for environment in ["production", "staging", "development", "test"] {
            let config = TelemetryBuildConfig.current(infoDictionary: [
                "WhiteNoiseTelemetryEnvironment": environment
            ], environment: [:])

            #expect(config.deploymentEnvironment == environment)
        }
    }

    @Test func oneMetricsTokenAndOneAuditTokenServeBothFlavors() {
        let environment = [
            "OTLP_TOKEN_WHITENOISE_IOS": "metrics-token",
            "AUDIT_LOG_TOKEN_WHITENOISE_IOS": "shared-audit-token"
        ]
        let production = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "production"
        ], environment: environment)
        let staging = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseTelemetryEnvironment": "staging"
        ], environment: environment)

        #expect(production.bearerToken == "metrics-token")
        #expect(staging.bearerToken == "metrics-token")
        #expect(production.auditLogBearerToken == "shared-audit-token")
        #expect(staging.auditLogBearerToken == "shared-audit-token")
        // The flavor stays distinguishable through the resource attribute.
        #expect(production.runtimeConfig(installId: "i").resource?.deploymentEnvironment == "production")
        #expect(staging.runtimeConfig(installId: "i").resource?.deploymentEnvironment == "staging")
    }

    @Test func auditTokenIsReadFromDedicatedKeyAndDoesNotFallBackToOtlpToken() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseAuditLogBearerToken": "$(WHITENOISE_AUDIT_LOG_BEARER_TOKEN)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "OTLP_TOKEN_WHITENOISE_IOS": "otlp-env-token",
            "AUDIT_LOG_TOKEN_WHITENOISE_IOS": "audit-env-token"
        ])

        #expect(config.bearerToken == "otlp-env-token")
        #expect(config.auditLogBearerToken == "audit-env-token")
        #expect(config.auditOtlpConfig().authorizationBearerToken == "audit-env-token")
    }

    @Test func auditTokenStaysNilWhenOnlyOtlpTokenIsConfigured() {
        let config = TelemetryBuildConfig.current(infoDictionary: [
            "WhiteNoiseTelemetryBearerToken": "$(WHITENOISE_OTLP_BEARER_TOKEN)",
            "WhiteNoiseAuditLogBearerToken": "$(WHITENOISE_AUDIT_LOG_BEARER_TOKEN)",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ], environment: [
            "OTLP_TOKEN_WHITENOISE_IOS": "otlp-env-token"
        ])

        // No dedicated audit token => audit delivery stays disabled rather than
        // borrowing the metrics token and authenticating against the wrong route.
        #expect(config.bearerToken == "otlp-env-token")
        #expect(config.auditLogBearerToken == nil)
        #expect(config.auditOtlpConfig().enabled == false)
    }
}
