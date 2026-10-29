import Foundation

// Compile with the production notification service; OS notification calls are
// replaced by deterministic fakes so the test never asks for permission.
struct Settings { var notifyEnabled = false; var notifyHour = 21 }

@main struct ReminderRegression {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("reminder coordinator did not settle")
    }

    @MainActor static func main() async {
        var permissionGate: CheckedContinuation<Bool, Never>?
        var pending: Int?
        var cancelCount = 0
        let first = ReminderCoordinator(requestPermission: {
            await withCheckedContinuation { permissionGate = $0 }
        }, schedule: { hour in pending = hour }, cancel: { pending = nil; cancelCount += 1 })
        first.apply(enabled:true, hour:21)
        await waitUntil { permissionGate != nil }
        first.apply(enabled:false, hour:21)
        permissionGate?.resume(returning:true); permissionGate = nil
        await waitUntil { cancelCount >= 2 }
        precondition(pending == nil, "a late permission result must not restore a disabled reminder")

        var addGate: CheckedContinuation<Void, Never>?
        var addStarted = false
        pending = nil; cancelCount = 0
        let second = ReminderCoordinator(requestPermission: { true }, schedule: { hour in
            addStarted = true
            await withCheckedContinuation { addGate = $0 }
            pending = hour
        }, cancel: { pending = nil; cancelCount += 1 })
        second.apply(enabled:true, hour:20)
        await waitUntil { addStarted && addGate != nil }
        second.apply(enabled:false, hour:20)
        addGate?.resume(); addGate = nil
        await waitUntil { cancelCount >= 2 }
        precondition(pending == nil, "an in-flight add must not resurrect a disabled reminder")

        var firstGate: CheckedContinuation<Void, Never>?
        var firstStarted = false
        pending = nil
        let third = ReminderCoordinator(requestPermission: { true }, schedule: { hour in
            if hour == 20 {
                firstStarted = true
                await withCheckedContinuation { firstGate = $0 }
            }
            pending = hour
        }, cancel: { pending = nil })
        third.apply(enabled:true, hour:20)
        await waitUntil { firstStarted && firstGate != nil }
        third.apply(enabled:true, hour:22)
        firstGate?.resume(); firstGate = nil
        await waitUntil { pending == 22 }
        precondition(pending == 22, "the newest reminder time must win")
        var deniedCancelled = false
        pending = 22
        let denied = ReminderCoordinator(requestPermission: { false }, schedule: { pending = $0 }, cancel: {
            pending = nil; deniedCancelled = true
        })
        denied.apply(enabled:true, hour:21)
        await waitUntil { deniedCancelled }
        precondition(pending == nil, "a denied permission must not leave an old reminder")
        precondition(denied.status == .denied, "denied permission must be visible")
        pending = 22
        denied.apply(enabled:true, hour:99)
        precondition(pending == nil, "an invalid hour must cancel the old reminder")
        precondition(denied.status == .invalidTime, "invalid time must be visible")

        enum Failure: Error { case injected }
        var attempts = 0
        let retry = ReminderCoordinator(requestPermission: { true }, schedule: { hour in
            attempts += 1
            if attempts == 1 { throw Failure.injected }
            pending = hour
        }, cancel: { pending = nil })
        retry.apply(enabled:true, hour:21)
        await waitUntil { retry.status == .failed }
        retry.apply(enabled:true, hour:21)
        await waitUntil { retry.status == .scheduled }
        precondition(pending == 21, "a failed schedule must be retryable")
        print("PASS reminder permission, disable, in-flight write and latest-setting races")
    }
}
