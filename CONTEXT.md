# ExtendCast

ExtendCast instances can act as senders and receivers independently. Outbound sending state and inbound receiving state belong to separate roles and must not be inferred from each other.

## Language

**Sender Role**:
The role that captures a local display and opens outbound streams to one or more Remote Receivers.
_Avoid_: Sender mode, sending side

**Receiver Role**:
The role that listens for and accepts inbound streams from one or more Remote Senders.
_Avoid_: Receiver mode, receiving side

**Remote Receiver**:
A destination selected by the local Sender Role. Its other inbound sessions are unrelated to the local sender's route discovery.
_Avoid_: Connected device, peer

**Remote Sender**:
A source connected to the local Receiver Role. It does not participate in the local Sender Role's route discovery.
_Avoid_: Client, peer

**Outbound Route**:
A concrete network path from the local Sender Role to one Remote Receiver, such as Wi-Fi, Ethernet, Thunderbolt Bridge, or Apple peer-to-peer.
_Avoid_: Line, channel, receiver connection

**Route Candidate**:
An Outbound Route suggested by discovery evidence but not yet verified as usable.
_Avoid_: Discovered device

**Available Route**:
An Outbound Route verified as usable for reaching its Remote Receiver.
_Avoid_: Active interface, discovered service

**Outbound Stream**:
An active media and input session from the local Sender Role to one Remote Receiver over a selected Available Route.
_Avoid_: Receiver session

**Inbound Session**:
An active media and input session accepted by the local Receiver Role from one Remote Sender.
_Avoid_: Sender connection, outbound stream

**Receiver Advertisement**:
The authoritative discovery announcement published by the local Receiver Role,
including the transport routes it currently offers and the concrete endpoint
for each route. Sender-local interfaces cannot add capabilities or invent
remote endpoints that are absent from this announcement.
_Avoid_: Sender broadcast, connection list

**Advertised Route Capability**:
A transport kind explicitly included in a Receiver Advertisement, such as
Wi-Fi, Ethernet, Thunderbolt Bridge, or Apple peer-to-peer.
_Avoid_: Inferred route, local interface guess

**Advertised Route Endpoint**:
An address and port explicitly paired with one Advertised Route Capability by
the Receiver, for example `ep_thunderbolt=169.254.204.111:51820`. It is a Route
Candidate until the Sender completes a transport handshake. ARP neighbors,
receiver names, and the number of discovered devices are not substitutes.
_Avoid_: Guessed peer, inferred endpoint

**Compatibility Inbound Connector**:
An explicit manual-address or ADB fallback that lets the local Receiver Role
dial a Remote Sender. It never participates in discovery, is never advertised,
and is never started automatically. Even though the Receiver opens the
transport, the resulting media flow is still an Inbound Session.
_Avoid_: Receiver discovery, active receiver route
