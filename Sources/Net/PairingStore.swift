import Foundation

struct SavedPairing: Sendable {
    let ticket: String
    let room: String
    let token: String
    let addr: String

    var complete: Bool { !ticket.isEmpty && !token.isEmpty }
}

/// 配对信息只保存在手机本地 UserDefaults；重启后自动重连。
enum PairingStore {
    private static let ticketKey = "cardai.pairing.ticket"
    private static let roomKey = "cardai.pairing.room"
    private static let tokenKey = "cardai.pairing.token"
    private static let addrKey = "cardai.pairing.addr"

    static func save(ticket: String, room: String, token: String, addr: String) {
        let defaults = UserDefaults.standard
        defaults.set(ticket, forKey: ticketKey)
        defaults.set(room, forKey: roomKey)
        defaults.set(token, forKey: tokenKey)
        defaults.set(addr, forKey: addrKey)
    }

    static func load() -> SavedPairing? {
        let defaults = UserDefaults.standard
        let ticket = defaults.string(forKey: ticketKey) ?? ""
        let token = defaults.string(forKey: tokenKey) ?? ""
        guard !ticket.isEmpty, !token.isEmpty else { return nil }
        return SavedPairing(ticket: ticket,
            room: defaults.string(forKey: roomKey) ?? "101",
            token: token,
            addr: defaults.string(forKey: addrKey) ?? "")
    }
}
