# The event log is canonical; SQLite schema is ours

The store is a plain SQLite file with a schema we define and migrate ourselves, holding an append-only event log. All other tables are Projections that can be rebuilt. We avoid SwiftData, Core Data and Room as the source of truth because they add their own tables and are not portable. Events carry a hybrid logical clock and UUID so that applying them in any order, any number of times, gives the same state.
