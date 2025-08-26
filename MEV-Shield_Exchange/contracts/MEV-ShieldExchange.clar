;; MEV-Shield Exchange Contract (revised)
;; Batch auction to limit MEV (front-running/sandwich)
;; Notes:
;; - Funds are escrowed to the contract on order submit and refunded on cancel.
;; - Batch execution/clearing is simplified (demo only).

(define-fungible-token shield-token)

;; -------------------- Constants & Errors --------------------
(define-constant contract-owner tx-sender)      ;; fixed at deploy time
(define-constant PRICE-SCALE u1)                ;; placeholder for price scaling (1 = no scaling)

(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INSUFFICIENT-BAL (err u102))
(define-constant ERR-AUCTION-NOT-ACTIVE (err u103))
(define-constant ERR-ORDER-EXISTS (err u104))
(define-constant ERR-INVALID-PRICE (err u105))
(define-constant ERR-INVALID-ORDER-TYPE (err u106))
(define-constant ERR-ORDER-NOT-FOUND (err u107))
(define-constant ERR-ORDER-ALREADY-EXEC (err u108))

;; -------------------- Auction State --------------------
(define-data-var auction-duration uint u10)        ;; blocks
(define-data-var current-auction-start uint u0)
(define-data-var auction-active bool false)
(define-data-var min-order-amount uint u1000000)   ;; 1 STX minimum (in micro-STX if used as such)

;; Order book
;; Important: key by global order-id to allow deterministic iteration if needed
(define-map orders
  { order-id: uint }
  {
    trader: principal,
    amount: uint,
    price: uint,
    side: (string-ascii 4),   ;; "buy" | "sell"
    timestamp: uint,
    executed: bool
  }
)

;; Index of orders per trader to allow quick lookup by user + id (optional convenience)
(define-map user-orders
  { trader: principal, order-id: uint }
  { exists: bool })

(define-data-var next-order-id uint u1)

;; Batch execution results
(define-data-var last-clearing-price uint u0)
(define-data-var total-volume-executed uint u0)

;; -------------------- Helpers --------------------

;; The contract principal (safe helper)
(define-read-only (contract-principal)
  (as-contract tx-sender))

;; Compute "cost" for buy orders with scaling: amount * price / PRICE-SCALE
(define-read-only (calc-cost (amount uint) (price uint))
  (ok (/ (* amount price) PRICE-SCALE)))

;; Internal: require active auction & still within window
(define-private (require-auction-open)
  (let (
        (active (var-get auction-active))
        (start (var-get current-auction-start))
        (end   (+ start (var-get auction-duration)))
       )
    (begin
      (asserts! active ERR-AUCTION-NOT-ACTIVE)
      ;; allow submits while current block <= end
      (asserts! (<= stacks-block-height end) ERR-AUCTION-NOT-ACTIVE)
      (ok true)
    )
  )
)

;; -------------------- Public: Submit Order --------------------
(define-public (submit-protected-order (amount uint) (price uint) (order-type (string-ascii 4)))
  (let (
        (order-id (var-get next-order-id))
        (cp (contract-principal))
       )
    (begin
      ;; validations
      (try! (require-auction-open))
      (asserts! (>= amount (var-get min-order-amount)) ERR-INVALID-AMOUNT)
      (asserts! (> price u0) ERR-INVALID-PRICE)
      (asserts! (or (is-eq order-type "buy") (is-eq order-type "sell")) ERR-INVALID-ORDER-TYPE)

      ;; prevent accidental collisions (not expected, but defensive)
      (asserts! (is-none (map-get? orders { order-id: order-id })) ERR-ORDER-EXISTS)

      ;; escrow funds
      (if (is-eq order-type "buy")
          ;; lock STX: from user to contract
          (let ((cost (unwrap! (calc-cost amount price) ERR-INVALID-PRICE)))
            (try! (stx-transfer? cost tx-sender cp)))
          ;; lock tokens: from user to contract
          (try! (ft-transfer? shield-token amount tx-sender cp))
      )

      ;; persist order in both indices
      (map-set orders
        { order-id: order-id }
        {
          trader: tx-sender,
          amount: amount,
          price: price,
          side: order-type,
          timestamp: stacks-block-height,
          executed: false
        })

      (map-set user-orders { trader: tx-sender, order-id: order-id } { exists: true })

      ;; bump id
      (var-set next-order-id (+ order-id u1))

      ;; event
      (print {
        event: "order-submitted",
        trader: tx-sender,
        order-id: order-id,
        amount: amount,
        price: price,
        side: order-type,
        block: stacks-block-height
      })

      (ok order-id)
    )
  )
)

;; -------------------- Public: Execute Batch --------------------
(define-public (execute-batch-auction)
  (let (
        (start (var-get current-auction-start))
        (end   (+ start (var-get auction-duration)))
       )
    (begin
      (asserts! (is-eq tx-sender contract-owner) ERR-OWNER-ONLY)
      (asserts! (var-get auction-active) ERR-AUCTION-NOT-ACTIVE)
      ;; must be strictly after the end
      (asserts! (> stacks-block-height end) ERR-AUCTION-NOT-ACTIVE)

      ;; trivial discovery (placeholder)
      (let ((clearing-price (calculate-clearing-price)))
        (begin
          (var-set last-clearing-price clearing-price)
          )

          ;; close auction explicitly
          (var-set auction-active false)

          (print {
            event: "batch-executed",
            clearing-price: clearing-price,
            execution-block: stacks-block-height
          })
          (ok clearing-price)
        )
      )
    )
  )


;; -------------------- Private: Batch Processing (simplified) --------------------
(define-private (process-batch-orders (clearing-price uint))
  (begin
    ;; In a production version, iterate deterministically over orders created during this auction,
    ;; match and settle at `clearing-price`, and mark executed=true.
    ;; For demo, reset the metric counter.
    (var-set total-volume-executed u0)
    (ok true)
  )
)

(define-private (calculate-clearing-price)
  (let ((base-price u1000000)) ;; demo: 1 STX
    base-price))

;; -------------------- Public: Start Auction --------------------
(define-public (start-new-auction)
  (begin
    (asserts! (is-eq tx-sender contract-owner) ERR-OWNER-ONLY)
    (asserts! (not (var-get auction-active)) ERR-AUCTION-NOT-ACTIVE)

    (var-set current-auction-start stacks-block-height)
    (var-set auction-active true)

    (print {
      event: "auction-started",
      start-block: stacks-block-height,
      duration: (var-get auction-duration)
    })

    (ok true)
  )
)

;; -------------------- Public: Cancel Order (refund) --------------------
(define-public (cancel-order (order-id uint))
  (let (
        (maybe (map-get? orders { order-id: order-id }))
        (cp (contract-principal))
       )
    (let ((od (unwrap! maybe ERR-ORDER-NOT-FOUND)))
      (begin
        (asserts! (is-eq (get trader od) tx-sender) ERR-OWNER-ONLY)
        (asserts! (var-get auction-active) ERR-AUCTION-NOT-ACTIVE)
        (asserts! (not (get executed od)) ERR-ORDER-ALREADY-EXEC)

        ;; refund escrowed funds from contract back to user
        (if (is-eq (get side od) "buy")
            (let ((cost (unwrap! (calc-cost (get amount od) (get price od)) ERR-INVALID-PRICE)))
              (as-contract (try! (stx-transfer? cost cp tx-sender))))
            (as-contract (try! (ft-transfer? shield-token (get amount od) cp tx-sender)))
        )

        ;; delete order in both indices
        (map-delete orders { order-id: order-id })
        (map-delete user-orders { trader: tx-sender, order-id: order-id })

        (print {
          event: "order-cancelled",
          trader: tx-sender,
          order-id: order-id
        })
        (ok true)
      )
    )
  )
)

;; -------------------- Read-only Views --------------------
(define-read-only (get-auction-status)
  (ok {
    active: (var-get auction-active),
    start-block: (var-get current-auction-start),
    duration: (var-get auction-duration),
    current-block: stacks-block-height,
    ends-at: (+ (var-get current-auction-start) (var-get auction-duration))
  })
)

(define-read-only (get-last-clearing-price)
  (ok (var-get last-clearing-price)))

(define-read-only (get-order-details (order-id uint))
  (ok (map-get? orders { order-id: order-id })))

(define-read-only (get-user-order-exists (trader principal) (order-id uint))
  (ok (map-get? user-orders { trader: trader, order-id: order-id })))

(define-read-only (get-min-order-amount)
  (ok (var-get min-order-amount)))

;; -------------------- Initialize --------------------
(define-public (initialize-exchange)
  (begin
    (asserts! (is-eq tx-sender contract-owner) ERR-OWNER-ONLY)
    (asserts! (not (var-get auction-active)) ERR-AUCTION-NOT-ACTIVE)

    (var-set current-auction-start stacks-block-height)
    (var-set auction-active true)

    (print {
      event: "exchange-initialized",
      start-block: stacks-block-height
    })

    (ok true)
  )
)
