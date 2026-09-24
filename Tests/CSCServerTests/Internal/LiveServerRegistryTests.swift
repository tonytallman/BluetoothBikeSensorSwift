import CSCServer
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LiveServerRegistryTests {
    @Test func claimReleaseSemantics() async throws {
        let registry = LiveServerRegistry()
        #expect(!registry.isOccupied)
        await registry.waitUntilVacant()

        let token = try #require(registry.claim())
        #expect(registry.isOccupied)
        #expect(registry.claim() == nil)

        registry.release(UUID())
        #expect(registry.isOccupied)

        let waiter = Task {
            await registry.waitUntilVacant()
            return registry.isOccupied
        }
        registry.release(token)
        #expect(await waiter.value == false)
        #expect(!registry.isOccupied)

        registry.release(token)
        #expect(!registry.isOccupied)

        let second = try #require(registry.claim())
        #expect(second != token)
        registry.release(second)
        #expect(!registry.isOccupied)
    }
}
