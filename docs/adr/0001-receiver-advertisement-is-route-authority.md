# Receiver advertisements are the route authority

The Receiver publishes one versioned advertisement containing its currently
offered route capabilities and the concrete `address:port` candidates paired
with each route. The current additive TXT contract is:

- `rv=1`
- `routes=wifi,ethernet,thunderbolt,p2p`
- `ep_wifi=<address:port>[,<address:port>...]`
- `ep_ethernet=<address:port>[,<address:port>...]`
- `ep_thunderbolt=<address:port>[,<address:port>...]`

The Sender may filter those capabilities by its own interfaces and must probe
the corresponding advertised endpoint before use. It must never create
Wi-Fi, Ethernet, Thunderbolt, or peer-to-peer capability or endpoint from
Sender-local topology, receiver naming, ARP entries, or device-count
heuristics. An advertised endpoint is a Route Candidate; only a successful
transport handshake makes it an Available Route. This keeps discovery correct
when several Receivers and several physical interfaces coexist.
