//
//  Item.swift
//  LuckyCat
//
//  Created by 李嘉俊 on 2026/11/20.
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
