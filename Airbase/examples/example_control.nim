## example_control.nim
## Example: Protocol simulation using Airbase.
## Demonstrates: state management, pre/post conditions, observe, tick

import ../src/airbase
import std/strutils

airspace ProtocolEngine:

  rule "connections progress monotonically toward terminal states"
  rule "data may not be sent in non-ESTABLISHED states"
  rule "no implicit connection teardown"
  rule "all protocol events are observable"

  # ─── Connection state ───────────────────────
  type
    ConnState = enum CLOSED, SYN_SENT, SYN_RECEIVED, ESTABLISHED, FIN_WAIT, CLOSE_WAIT, TIME_WAIT

  var connectionState = CLOSED

  # ─── Protocol operations ─────────────────────
  proc sendData(data: string) =
    ## Data may only be sent in ESTABLISHED state
    grounded_if(
      connectionState != ESTABLISHED,
      "data transmission requires ESTABLISHED state, currently: " & $connectionState
    )
    emit_obs("tcp.data", data)

  proc openConnection(host: string) =
    pre(host.len > 0, "host must be specified")
    grounded_if(connectionState != CLOSED,
      "can only open from CLOSED state")

    connectionState = SYN_SENT
    tick("SYN sent")
    emit_obs("tcp.connect", host)

  proc handshake() =
    pre(connectionState == SYN_SENT,
        "handshake requires SYN_SENT state")

    connectionState = SYN_RECEIVED
    tick("SYN-ACK received")

    connectionState = ESTABLISHED
    tick("ACK sent — connection established")

    must(connectionState == ESTABLISHED,
         "handshake must result in ESTABLISHED")
    emit_obs("tcp.established", "true")

  proc closeConnection() =
    pre(connectionState == ESTABLISHED,
        "can only close ESTABLISHED connection")

    connectionState = FIN_WAIT
    tick("FIN sent")

    connectionState = TIME_WAIT
    tick("FIN-ACK received — entering TIME_WAIT")

    must(connectionState == TIME_WAIT,
         "connection must be in terminal state after close")
    emit_obs("tcp.closed", "TIME_WAIT")

  # ─── Run a protocol session ──────────────────────────
  declare_power([branch, allocate], "TCP session simulation"):

    let initialProof = axiom("connection starts in CLOSED state")
    emit_obs("proof.loaded", $initialProof)

    # Establish connection
    openConnection("example.com")
    handshake()

    # Send data — only valid in ESTABLISHED
    sendData("GET / HTTP/1.1")
    sendData("Host: example.com")
    tick("request sent")

    # Close cleanly
    closeConnection()

    # Final assertions
    must(connectionState == TIME_WAIT,
         "connection reached terminal state")

    # Verify the protocol was followed via emission log
    let log = globalAirspace.emissionLog()
    var sawEstablished = false
    var sawClosed = false
    for entry in log:
      if entry.contains("tcp.established"): sawEstablished = true
      if entry.contains("tcp.closed"): sawClosed = true

    must(sawEstablished, "ESTABLISHED state was reached")
    must(sawClosed, "connection was properly closed")

  certify("ProtocolEngine",
    axioms = @[
      "state transitions are explicit",
      "data transmission guarded by state check",
      "connection lifecycle is observable end-to-end",
      "terminal state is verifiable after close"
    ],
    power = @[
      "branch: protocol routing",
      "allocate: connection objects"
    ]
  )

  audit()
