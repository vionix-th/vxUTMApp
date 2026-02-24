//
//  Item.swift
//  UTMSnapshotsApp
//
//  Created by Stefan Brueck on 24.02.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
