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
