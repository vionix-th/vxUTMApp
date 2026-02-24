//
//  UTMSnapshotsAppApp.swift
//  UTMSnapshotsApp
//
//  Created by Stefan Brueck on 24.02.26.
//

import SwiftUI
import SwiftData

@main
struct UTMSnapshotsAppApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
