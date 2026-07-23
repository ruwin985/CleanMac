import SwiftUI

@main
struct CleanMacApp: App {
    @StateObject private var viewModel = StorageDashboardViewModel()

    var body: some Scene {
        WindowGroup {
            StorageDashboardView(viewModel: viewModel)
                .frame(minWidth: 1100, minHeight: 760)
        }
        .windowResizability(.contentSize)
    }
}
