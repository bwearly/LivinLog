//
//  CoreDateHelpers.swift
//  Livin Log
//
//  Created by Blake Early on 1/5/26.
//

import CoreData

@discardableResult
func fetchOrCreateDefaultHousehold(in context: NSManagedObjectContext) -> Household {
    let request = Household.fetchRequest()
    request.fetchLimit = 1

    if let existing = (try? context.fetch(request))?.first as? Household {
        return existing
    }

    let household = Household(context: context)
    household.id = UUID()
    household.createdAt = Date()
    household.name = "My Household"

    do { try context.save() }
    catch { print("Core Data save error:", error) }

    return household
}
