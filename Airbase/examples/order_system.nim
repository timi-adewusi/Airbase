## order_system.nim
## Example: E-commerce order system state machine
## Demonstrates: State transitions, guarded values, observations, explicit time

import ../src/airbase

airspace OrderSystem:

  rule "orders transition through predefined states"
  rule "payment required before fulfillment"
  rule "all state changes are observable"
  rule "order ID is preserved throughout lifecycle"

  # ─── Order state ────────────────────────────────────────
  type
    OrderState = enum Pending, Confirmed, Paid, Fulfilling, Shipped, Delivered

  var orderState = Pending
  let orderId = "ORD-12345"
  var totalAmount = 149.99
  var isPaid = false

  # ─── Order operations ───────────────────────────────────
  proc confirmOrder() =
    pre(orderState == Pending, "order must be Pending")
    orderState = Confirmed
    tick("order confirmed")
    emit_obs("order.confirmed", orderId)

  proc recordPayment(amount: float) =
    pre(orderState == Confirmed, "order must be Confirmed before payment")
    pre(amount >= totalAmount, "payment amount insufficient")
    isPaid = true
    orderState = Paid
    tick("payment received")
    must(isPaid, "payment must be recorded")
    emit_obs("order.paid", $amount)

  proc startFulfillment() =
    pre(orderState == Paid, "order must be Paid")
    pre(isPaid, "order must be marked paid")
    orderState = Fulfilling
    tick("fulfillment started")
    emit_obs("order.fulfilling", "warehouse")

  proc shipOrder(carrier: string) =
    pre(orderState == Fulfilling, "order must be in Fulfilling state")
    orderState = Shipped
    tick("order shipped")
    emit_obs("order.shipped", carrier)

  proc deliverOrder() =
    pre(orderState == Shipped, "order must be Shipped")
    orderState = Delivered
    tick("order delivered")
    must(orderState == Delivered, "final state must be Delivered")
    emit_obs("order.delivered", orderId)

  # ─── Run an order through full lifecycle ─────────────────
  declare_power([branch, allocate], "order processing"):

    emit_obs("demo.start", "Order System Lifecycle")

    # Create and confirm order
    tick("order created")
    emit_obs("order.created", orderId)
    confirmOrder()

    # Process payment
    recordPayment(totalAmount)

    # Fulfill order
    startFulfillment()

    # Ship order
    shipOrder("FastShip Logistics")

    # Deliver order
    deliverOrder()

    # Verify order reached terminal state
    must(orderState == Delivered, "order must be delivered")
    assert(isPaid, "payment must be recorded")

    emit_obs("demo.complete", "Order processed successfully")

  certify("OrderSystem",
    axioms = @[
      "order starts in Pending state",
      "state transitions are acyclic",
      "payment must occur before fulfillment",
      "all state changes are observable",
      "final state is Delivered"
    ],
    power = @[
      "branch: payment validation",
      "branch: fulfillment routing",
      "allocate: order context"
    ]
  )

  audit()

