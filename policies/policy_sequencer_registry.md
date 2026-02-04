# Sequencer Service-Level Policy

## 1. Preamble
This registry lists authorized Sequencer Operators for the KSSN network. Inclusion signals that an Operator meets baseline reliability, security, and operational readiness standards. This policy is a service-level agreement (SLA) focused on uptime, rotation behavior, and operational hygiene. It is intentionally neutral on transaction content and does not prescribe censorship or inclusion rules.

## 2. Acceptance Criteria (Registration Requirements)
To be accepted into the registry, a submission must satisfy **ALL** of the following criteria.

### A. Operational Security (Recommended)
* **Recommendation:** It is **strongly recommended** (but not required) that the Staker Address be different from Operational Keys.
* **Rationale:** This protects governance stake if hot sequencer keys are compromised.

### B. Sybil Resistance (Distinct Entity)
* **Requirement:** The Applicant must plausibly demonstrate they are a **distinct, independent entity** from other active operators.
* **Verification:** Any **ONE OR MORE** of the following:
  * **Reputation Link:** Established GitHub org, X.com profile, or company website with >6 months of activity.
  * **Proof of Humanity:** A valid profile linked to the staker address.
  * **Cryptographic Attestation:** A signature from a reputable ecosystem entity vouching for the operator.

### C. Operational Readiness Declaration
* **Requirement:** The submission must include the following declaration:
  > "I certify that I operate sequencer infrastructure capable of meeting KSSN SLA requirements, including active handoff procedures and monitoring. I agree that persistent SLA violations can lead to removal from this registry."

## 3. Service-Level Requirements (Grounds for Removal)

### I. Authorized Production
* **Violation:** Producing a block or posting a batch while not the current active sequencer as determined by the Hub’s rotation state.
* **Rationale:** This enforces clean ownership of sequencing authority and avoids conflicting state updates.

### II. Active Handoff Compliance
Operators must execute an orderly handoff at epoch end to prevent L2 re-orgs.

* **Requirement:** At epoch end, the Operator MUST:
  1. Stop accepting new transactions.
  2. Flush pending unsafe blocks to L1 via `op-batcher`.
  3. Call `rotateNetwork()` within the configured grace period.

* **Violation:** Failing to rotate within the grace period, causing a third party to force rotation.
* **Rationale:** The Active Handoff protocol ensures seamless transitions and minimizes user disruption.

### III. Liveness & Availability
* **Violation:** Failing to produce blocks for more than **5 minutes** during the Operator’s assigned epoch, absent an L1 outage or global OP Stack halt.
* **Rationale:** Sequencer reliability is the core SLA guarantee.

### IV. Incident Response
* **Requirement:** Operators must provide a post-incident summary (root cause + mitigation) within a reasonable time after a sustained outage or missed handoff.

## 4. Evidence Standards
Challengers must submit evidence meeting the following standards.

### A. Unauthorized Production
* **Required Evidence:**
  1. L1 transaction hash where the batch was posted.
  2. Proof the timestamp was outside the operator’s active epoch.

### B. Active Handoff Violations
* **Required Evidence:**
  1. Proof that the grace period expired without the operator calling `rotateNetwork()`.
  2. The transaction hash where a third party forced rotation.

### C. Liveness Failures
* **Required Evidence:**
  1. Block gap analysis or missing block production timestamps covering the outage window.
  2. Corroborating node logs or explorer evidence showing sustained non-production.
