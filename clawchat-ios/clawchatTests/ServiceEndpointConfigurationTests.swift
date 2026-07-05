import Foundation
import Testing
@testable import clawchat

struct ServiceEndpointConfigurationTests {
    @Test func normalizesCustomEndpointWithoutScheme() throws {
        let url = try #require(ServiceEndpointConfiguration.normalizedURL(from: "test.iotdevices.site"))

        #expect(url.absoluteString == "https://test.iotdevices.site")
    }

    @Test func rejectsUnsupportedCustomEndpointScheme() throws {
        let url = ServiceEndpointConfiguration.normalizedURL(from: "ftp://test.iotdevices.site")

        #expect(url == nil)
    }

    @Test func usesChinaEndpointForChinaPreset() throws {
        let url = ServiceEndpointConfiguration.endpointURL(for: .china, customEndpointText: "")

        #expect(url?.absoluteString == "https://test.iotdevices.site")
    }

    @Test func createsStableStorageIdentifierFromEndpoint() throws {
        let url = try #require(URL(string: "https://test.iotdevices.site"))

        #expect(ServiceEndpointConfiguration.storageIdentifier(for: url) == "https-test-iotdevices-site")
    }
}
