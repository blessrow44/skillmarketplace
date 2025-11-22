;; Skill Marketplace - Decentralized Freelance Platform
;; A trustless escrow-based job marketplace for the Stacks ecosystem

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-authorized (err u201))
(define-constant err-job-not-found (err u202))
(define-constant err-invalid-amount (err u203))
(define-constant err-invalid-status (err u204))
(define-constant err-job-already-accepted (err u205))
(define-constant err-deadline-not-passed (err u206))
(define-constant err-already-submitted (err u207))
(define-constant err-not-submitted (err u208))
(define-constant err-dispute-window-closed (err u209))
(define-constant err-invalid-percentage (err u210))
(define-constant err-marketplace-paused (err u211))
(define-constant err-cannot-cancel (err u212))
(define-constant err-invalid-milestone (err u213))

;; Job status constants
(define-constant status-open u1)
(define-constant status-accepted u2)
(define-constant status-submitted u3)
(define-constant status-completed u4)
(define-constant status-disputed u5)
(define-constant status-cancelled u6)

;; Time constants (in blocks)
(define-constant dispute-window u500)        ;; ~3.5 days to raise dispute
(define-constant auto-release-buffer u1000)  ;; ~7 days after deadline
(define-constant dispute-resolution-time u2000) ;; ~14 days to resolve

;; Data Variables
(define-data-var marketplace-paused bool false)
(define-data-var total-jobs-created uint u0)
(define-data-var total-jobs-completed uint u0)
(define-data-var total-volume-traded uint u0)

;; Data Maps

;; Main job storage
(define-map jobs
  uint  ;; job-id
  {
    client: principal,
    freelancer: (optional principal),
    amount: uint,
    deadline: uint,
    status: uint,
    created-at: uint,
    accepted-at: (optional uint),
    submitted-at: (optional uint),
    completed-at: (optional uint),
    description: (string-ascii 500),
    deliverable: (optional (string-ascii 500)),
    milestones-total: uint,
    milestones-released: uint,
    dispute-raised-at: (optional uint)
  }
)

;; User reputation tracking
(define-map user-reputation
  principal
  {
    jobs-completed: uint,
    jobs-created: uint,
    total-earned: uint,
    total-spent: uint,
    disputes-raised: uint,
    disputes-lost: uint,
    success-rate: uint  ;; Percentage (0-10000 = 0-100%)
  }
)

;; Job counter per user
(define-map user-job-count principal uint)

;; Private Functions

(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (is-job-client (job-id uint))
  (match (map-get? jobs job-id)
    job (is-eq tx-sender (get client job))
    false
  )
)

(define-private (is-job-freelancer (job-id uint))
  (match (map-get? jobs job-id)
    job (match (get freelancer job)
      freelancer-addr (is-eq tx-sender freelancer-addr)
      false
    )
    false
  )
)

(define-private (get-or-create-reputation (user principal))
  (default-to
    {
      jobs-completed: u0,
      jobs-created: u0,
      total-earned: u0,
      total-spent: u0,
      disputes-raised: u0,
      disputes-lost: u0,
      success-rate: u10000
    }
    (map-get? user-reputation user)
  )
)

(define-private (update-client-reputation (client principal) (amount uint) (successful bool))
  (let
    (
      (current-rep (get-or-create-reputation client))
      (new-jobs-created (+ (get jobs-created current-rep) u1))
      (new-spent (+ (get total-spent current-rep) amount))
      (new-success-rate (if successful
        (get success-rate current-rep)
        (calculate-new-success-rate 
          (get success-rate current-rep)
          (get jobs-created current-rep)
          false
        )
      ))
    )
    (map-set user-reputation client
      (merge current-rep {
        jobs-created: new-jobs-created,
        total-spent: new-spent,
        success-rate: new-success-rate
      })
    )
  )
)

(define-private (update-freelancer-reputation (freelancer principal) (amount uint) (successful bool))
  (let
    (
      (current-rep (get-or-create-reputation freelancer))
      (new-jobs-completed (if successful (+ (get jobs-completed current-rep) u1) (get jobs-completed current-rep)))
      (new-earned (if successful (+ (get total-earned current-rep) amount) (get total-earned current-rep)))
      (new-success-rate (calculate-new-success-rate 
        (get success-rate current-rep)
        (get jobs-completed current-rep)
        successful
      ))
    )
    (map-set user-reputation freelancer
      (merge current-rep {
        jobs-completed: new-jobs-completed,
        total-earned: new-earned,
        success-rate: new-success-rate
      })
    )
  )
)

(define-private (calculate-new-success-rate (current-rate uint) (total-jobs uint) (success bool))
  (let
    (
      (current-successes (/ (* current-rate total-jobs) u10000))
      (new-successes (if success (+ current-successes u1) current-successes))
      (new-total (+ total-jobs u1))
    )
    (if (is-eq new-total u0)
      u10000
      (/ (* new-successes u10000) new-total)
    )
  )
)

;; Public Functions

;; Create a new job listing
(define-public (create-job (amount uint) (deadline-blocks uint) (description (string-ascii 500)))
  (let
    (
      (job-id (var-get total-jobs-created))
      (client tx-sender)
      (deadline (+ stacks-block-height deadline-blocks))
    )
    ;; Validations
    (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (>= amount u1000000) err-invalid-amount) ;; Minimum 1 STX
    (asserts! (> deadline-blocks u0) err-invalid-amount)
    (asserts! (> (len description) u0) err-invalid-amount)
    
    ;; Transfer payment to escrow (this contract)
    (try! (stx-transfer? amount client (as-contract tx-sender)))
    
    ;; Create job entry
    (map-set jobs job-id
      {
        client: client,
        freelancer: none,
        amount: amount,
        deadline: deadline,
        status: status-open,
        created-at: stacks-block-height,
        accepted-at: none,
        submitted-at: none,
        completed-at: none,
        description: description,
        deliverable: none,
        milestones-total: u1,
        milestones-released: u0,
        dispute-raised-at: none
      }
    )
    
    ;; Update counters
    (var-set total-jobs-created (+ job-id u1))
    (var-set total-volume-traded (+ (var-get total-volume-traded) amount))
    
    ;; Update client reputation
    (update-client-reputation client amount true)
    
    (ok job-id)
  )
)

;; Freelancer accepts a job
(define-public (accept-job (job-id uint))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
      (freelancer tx-sender)
    )
    ;; Validations
    (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
    (asserts! (is-eq (get status job) status-open) err-invalid-status)
    (asserts! (is-none (get freelancer job)) err-job-already-accepted)
    (asserts! (not (is-eq freelancer (get client job))) err-not-authorized)
    
    ;; Update job with freelancer
    (map-set jobs job-id
      (merge job {
        freelancer: (some freelancer),
        status: status-accepted,
        accepted-at: (some stacks-block-height)
      })
    )
    
    (ok true)
  )
)

;; Freelancer submits completed work
(define-public (submit-deliverable (job-id uint) (deliverable (string-ascii 500)))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
    )
    ;; Validations
    (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
    (asserts! (is-job-freelancer job-id) err-not-authorized)
    (asserts! (is-eq (get status job) status-accepted) err-invalid-status)
    (asserts! (> (len deliverable) u0) err-invalid-amount)
    
    ;; Update job with deliverable
    (map-set jobs job-id
      (merge job {
        status: status-submitted,
        submitted-at: (some stacks-block-height),
        deliverable: (some deliverable)
      })
    )
    
    (ok true)
  )
)

;; Client approves work and releases payment
(define-public (approve-work (job-id uint))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
      (freelancer (unwrap! (get freelancer job) err-not-authorized))
      (amount (get amount job))
    )
    ;; Validations
    (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
    (asserts! (is-job-client job-id) err-not-authorized)
    (asserts! (is-eq (get status job) status-submitted) err-not-submitted)
    
    ;; Update job status
    (map-set jobs job-id
      (merge job {
        status: status-completed,
        completed-at: (some stacks-block-height),
        milestones-released: (get milestones-total job)
      })
    )
    
    ;; Transfer payment to freelancer
    (try! (as-contract (stx-transfer? amount tx-sender freelancer)))
    
    ;; Update reputations
    (update-freelancer-reputation freelancer amount true)
    (update-client-reputation (get client job) amount true)
    
    ;; Update stats
    (var-set total-jobs-completed (+ (var-get total-jobs-completed) u1))
    
    (ok amount)
  )
)

;; Cancel job (only before acceptance, full refund)
(define-public (cancel-job (job-id uint))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
      (client (get client job))
      (amount (get amount job))
    )
    ;; Validations
    (asserts! (is-job-client job-id) err-not-authorized)
    (asserts! (is-eq (get status job) status-open) err-cannot-cancel)
    (asserts! (is-none (get freelancer job)) err-cannot-cancel)
    
    ;; Update job status
    (map-set jobs job-id
      (merge job { status: status-cancelled })
    )
    
    ;; Refund client
    (try! (as-contract (stx-transfer? amount tx-sender client)))
    
    (ok amount)
  )
)

;; Raise a dispute
(define-public (raise-dispute (job-id uint))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
      (submitted-time (unwrap! (get submitted-at job) err-not-submitted))
    )
    ;; Validations
    (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
    (asserts! (or (is-job-client job-id) (is-job-freelancer job-id)) err-not-authorized)
    (asserts! (is-eq (get status job) status-submitted) err-invalid-status)
    (asserts! (<= (- stacks-block-height submitted-time) dispute-window) err-dispute-window-closed)
    
    ;; Update job status
    (map-set jobs job-id
      (merge job {
        status: status-disputed,
        dispute-raised-at: (some stacks-block-height)
      })
    )
    
    ;; Update dispute counter for user
    (let
      (
        (disputer tx-sender)
        (rep (get-or-create-reputation disputer))
      )
      (map-set user-reputation disputer
        (merge rep { disputes-raised: (+ (get disputes-raised rep) u1) })
      )
    )
    
    (ok true)
  )
)

;; Owner resolves dispute with percentage split (0-10000 = 0-100%)
(define-public (resolve-dispute (job-id uint) (client-percentage uint))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
      (client (get client job))
      (freelancer (unwrap! (get freelancer job) err-not-authorized))
      (amount (get amount job))
      (client-amount (/ (* amount client-percentage) u10000))
      (freelancer-amount (- amount client-amount))
    )
    ;; Validations
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (is-eq (get status job) status-disputed) err-invalid-status)
    (asserts! (<= client-percentage u10000) err-invalid-percentage)
    
    ;; Update job status
    (map-set jobs job-id
      (merge job {
        status: status-completed,
        completed-at: (some stacks-block-height)
      })
    )
    
    ;; Transfer funds according to resolution
    (if (> client-amount u0)
      (try! (as-contract (stx-transfer? client-amount tx-sender client)))
      true
    )
    (if (> freelancer-amount u0)
      (try! (as-contract (stx-transfer? freelancer-amount tx-sender freelancer)))
      true
    )
    
    ;; Update reputations based on outcome
    (update-freelancer-reputation freelancer freelancer-amount (> freelancer-amount u0))
    (update-client-reputation client client-amount (> client-amount u0))
    
    (ok { client-amount: client-amount, freelancer-amount: freelancer-amount })
  )
)

;; Emergency withdrawal after deadline + buffer period
(define-public (emergency-withdraw (job-id uint))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
      (freelancer (unwrap! (get freelancer job) err-not-authorized))
      (amount (get amount job))
      (deadline (get deadline job))
      (auto-release-time (+ deadline auto-release-buffer))
    )
    ;; Validations
    (asserts! (is-job-freelancer job-id) err-not-authorized)
    (asserts! (is-eq (get status job) status-submitted) err-invalid-status)
    (asserts! (>= stacks-block-height auto-release-time) err-deadline-not-passed)
    
    ;; Update job status
    (map-set jobs job-id
      (merge job {
        status: status-completed,
        completed-at: (some stacks-block-height),
        milestones-released: (get milestones-total job)
      })
    )
    
    ;; Transfer payment to freelancer
    (try! (as-contract (stx-transfer? amount tx-sender freelancer)))
    
    ;; Update reputations
    (update-freelancer-reputation freelancer amount true)
    
    ;; Update stats
    (var-set total-jobs-completed (+ (var-get total-jobs-completed) u1))
    
    (ok amount)
  )
)

;; Release milestone payment (for multi-milestone projects)
(define-public (release-milestone (job-id uint) (milestone-amount uint))
  (let
    (
      (job (unwrap! (map-get? jobs job-id) err-job-not-found))
      (freelancer (unwrap! (get freelancer job) err-not-authorized))
      (released (get milestones-released job))
      (total (get milestones-total job))
    )
    ;; Validations
    (asserts! (not (var-get marketplace-paused)) err-marketplace-paused)
    (asserts! (is-job-client job-id) err-not-authorized)
    (asserts! (< released total) err-invalid-milestone)
    (asserts! (<= milestone-amount (get amount job)) err-invalid-amount)
    
    ;; Update milestones counter
    (map-set jobs job-id
      (merge job {
        milestones-released: (+ released u1)
      })
    )
    
    ;; Transfer milestone payment
    (try! (as-contract (stx-transfer? milestone-amount tx-sender freelancer)))
    
    (ok milestone-amount)
  )
)

;; Administrative Functions

(define-public (pause-marketplace)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set marketplace-paused true)
    (ok true)
  )
)

(define-public (resume-marketplace)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set marketplace-paused false)
    (ok true)
  )
)

;; Read-Only Functions

(define-read-only (get-job-details (job-id uint))
  (map-get? jobs job-id)
)

(define-read-only (get-user-reputation (user principal))
  (get-or-create-reputation user)
)

(define-read-only (get-marketplace-stats)
  {
    total-jobs: (var-get total-jobs-created),
    completed-jobs: (var-get total-jobs-completed),
    total-volume: (var-get total-volume-traded),
    is-paused: (var-get marketplace-paused)
  }
)

(define-read-only (can-raise-dispute (job-id uint))
  (match (map-get? jobs job-id)
    job (match (get submitted-at job)
      submitted-time (and
        (is-eq (get status job) status-submitted)
        (<= (- stacks-block-height submitted-time) dispute-window)
      )
      false
    )
    false
  )
)

(define-read-only (can-emergency-withdraw (job-id uint))
  (match (map-get? jobs job-id)
    job (and
      (is-eq (get status job) status-submitted)
      (>= stacks-block-height (+ (get deadline job) auto-release-buffer))
    )
    false
  )
)

(define-read-only (get-job-status (job-id uint))
  (match (map-get? jobs job-id)
    job (ok (get status job))
    err-job-not-found
  )
)

(define-read-only (is-job-active (job-id uint))
  (match (map-get? jobs job-id)
    job (and
      (< (get status job) status-completed)
      (not (is-eq (get status job) status-cancelled))
    )
    false
  )
)