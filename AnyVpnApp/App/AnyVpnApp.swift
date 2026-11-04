import SwiftUI

@main
struct AnyVpnApplication: App {
    @StateObject private var vpn = VPNManager()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(vpn)
        }
    }
}
