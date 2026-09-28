import Foundation
import Testing
@testable import ClementineKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OutputTests {
    nonisolated static let phone = "phone-id"

    /// Clementine with remote streaming: it says so, and lists its computer and this phone.
    static func streamingClementine(active: String = Output.local) -> [RemoteMessage] {
        [
            RemoteMessage(.info) {
                $0.responseClementineInfo.version = "1.4.1"
                $0.responseClementineInfo.features = [.rendering]
            },
            RemoteMessage(.outputs) {
                $0.responseOutputs.outputs = [(Output.local, "studio-pc"), (phone, "iPhone")].map { id, name in
                    var output = Pb_Remote_Output()
                    output.outputID = id
                    output.displayName = name
                    output.state = id == active ? .active : .available
                    return output
                }
            },
        ]
    }

    @Test func offersThePhoneAndListsOutputs() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine(extra: Self.streamingClementine())

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0,
                        renderer: Renderer.capabilities(id: Self.phone, name: "iPhone"))
        try await eventually { session.outputs.count == 2 }

        let connect = try #require(clementine.received.first)
        #expect(connect.requestConnect.hasRenderer)
        #expect(connect.requestConnect.renderer.rendererID == Self.phone)
        try await clementine.waitUntil { $0.received.contains { $0.type == .requestOutputs } }

        #expect(session.canChooseOutput)
        #expect(session.hasOtherOutputs)
        #expect(session.activeOutput?.isLocal == true)
        #expect(!session.isPlayingHere)

        session.setOutput(Self.phone)
        #expect(session.outputs.first { $0.id == Self.phone }?.state == .activating)
        try await clementine.waitUntil {
            $0.received.contains { $0.type == .setOutput && $0.requestSetOutput.outputID == Self.phone }
        }
        await clementine.broadcast(Self.streamingClementine(active: Self.phone)[1])
        try await eventually { session.isPlayingHere }
    }

    @Test func withoutStreamingThereIsNothingToChoose() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0,
                        renderer: Renderer.capabilities(id: Self.phone, name: "iPhone"))
        try await eventually { session.status == .connected }
        #expect(!session.canChooseOutput)
        #expect(!session.hasOtherOutputs)
        #expect(!clementine.received.contains { $0.type == .requestOutputs })
    }

    @Test func connectsWithoutOfferingThePhone() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }
        #expect(clementine.received.first?.requestConnect.hasRenderer == false)
    }
}
