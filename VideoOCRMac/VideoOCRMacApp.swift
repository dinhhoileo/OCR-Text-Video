import SwiftUI

@main
struct VideoOCRMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacContentView()
                .frame(minWidth: 960, minHeight: 680)
        }
        .windowResizability(.contentSize)
    }
}
