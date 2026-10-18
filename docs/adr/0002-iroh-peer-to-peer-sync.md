# Peer-to-peer Sync over iroh, no server and no CloudKit

Devices sync directly using iroh connections and a Sync protocol we own. CloudKit was rejected because it is Apple-only and would force a second path for other platforms; a hosted backend was rejected because the product is local only. The iroh bindings cover only the stable core (endpoints, connections, tickets, relays), so the replication logic is ours, not iroh-docs. The cost is that two Devices must be online together (or via a third that is) to exchange Events.
