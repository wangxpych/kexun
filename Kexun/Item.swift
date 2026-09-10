//
//  Item.swift
//  Kexun
//
//  Created by wxp on 2026/9/5.
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
