import Carbon
import Foundation
import GPTSwitcherCore

private var globalHotKeyCallbacks: [UInt32: () -> Void] = [:]
private var globalHotKeyHandler: EventHandlerRef?

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var references: [EventHotKeyRef] = []

    private init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, let callback = globalHotKeyCallbacks[identifier.id] else {
                    return status
                }
                DispatchQueue.main.async(execute: callback)
                return noErr
            },
            1,
            &eventType,
            nil,
            &globalHotKeyHandler
        )
    }

    func register(
        shortcuts: [ProfileID: HotKeyConfiguration],
        accountOrder: [ProfileID],
        onPressed: @escaping (ProfileID) -> Void
    ) {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        globalHotKeyCallbacks.removeAll()

        for (index, id) in accountOrder.enumerated() {
            guard let shortcut = shortcuts[id], let keyCode = Self.keyCode(shortcut.key) else { continue }
            let numericID = UInt32(index + 1)
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: numericID)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                Self.modifiers(shortcut),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                references.append(reference)
                globalHotKeyCallbacks[numericID] = { onPressed(id) }
            }
        }
    }

    private static let signature: OSType = 0x47505453 // GPTS

    private static func modifiers(_ value: HotKeyConfiguration) -> UInt32 {
        var result: UInt32 = 0
        if value.command { result |= UInt32(cmdKey) }
        if value.option { result |= UInt32(optionKey) }
        if value.control { result |= UInt32(controlKey) }
        if value.shift { result |= UInt32(shiftKey) }
        return result
    }

    static func keyCode(_ raw: String) -> UInt32? {
        let map: [String: UInt32] = [
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
            "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B),
            "C": UInt32(kVK_ANSI_C), "D": UInt32(kVK_ANSI_D),
            "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F),
            "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H),
            "I": UInt32(kVK_ANSI_I), "J": UInt32(kVK_ANSI_J),
            "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
            "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N),
            "O": UInt32(kVK_ANSI_O), "P": UInt32(kVK_ANSI_P),
            "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R),
            "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T),
            "U": UInt32(kVK_ANSI_U), "V": UInt32(kVK_ANSI_V),
            "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
            "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z),
        ]
        return map[raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }
}
