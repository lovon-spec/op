# Constitutional L2 Sequencer Policy

## 1. Preamble
This Registry serves as the list of authorized Sequencers for the Constitutional L2. Inclusion in this list constitutes a "License to Operate." By registering, the Operator agrees to strictly adhere to the rules defined in this Constitution.


## 2. Acceptance Criteria (Registration Requirements)

To be accepted into the registry, a submission must satisfy **ALL** of the following criteria.

### A. Operational Security (Recommended)

* **Recommendation:** It is **strongly recommended** (but not required) that the Staker Address be different from the Operational Keys.
* **Rationale:** This protects the governance stake if the hot sequencer keys are compromised. Operators using a single address for all roles assume full liability for any security breaches.

### B. Sybil Resistance (The "Distinct Entity" Rule)

* **Requirement:** The Applicant must plausibly demonstrate that they are a **distinct, independent entity** from all other currently active operators.
* **Verification:** The Applicant may prove this via **ONE or MORE** of the following methods (Operator's choice):
    * **Reputation Link:** A link to an established GitHub organization, X.com profile, or Company Website with a history of activity (>6 months).
    * **Proof of Humanity:** A valid Proof of Humanity profile linked to the Staker address.
    * **Cryptographic Attestation:** A signature from a known reputable entity in the ecosystem vouching for the operator.


* **Rejection Criteria:** Jurors shall reject submissions that appear to be "Sock Puppets" or "Sybil Attackers" (e.g., brand new GitHub accounts created yesterday, identical server metadata to an existing node, or sequential naming patterns like "Node-01", "Node-02" owned by the same entity).

### C. Operational Readiness

* **Requirement:** The submission must include the **"Constitutional Declaration"**:
> "I certify that I have deployed the required Self-Activation Agent and my infrastructure meets the minimum hardware requirements. I agree to be slashed if my Sequencer violates the Constitution."



## 3. Constitutional Rules (Grounds for Removal)

### I. Censorship Resistance (The "Must Include" Rule)
Operators must not systematically exclude valid transactions.
* **Violation:** A transaction $T$ is considered "Censored" if:
    1.  It was valid and paid a sufficient gas fee.
    2.  It was broadcast to the P2P network and visible in the public mempool.
    3.  The Operator produced multiple blocks with available gas capacity.
    4.  The transaction was excluded for a duration exceeding **5 minutes** (or ~150 blocks).
* **Defense:** The Operator may prove the transaction was invalid, reverted during simulation, or that the network was congested (blocks were full).

### II. Malicious MEV (The "No Robbery" Rule)
Operators must not manipulate transaction ordering to extract value from users.
* **Violation:** "Sandwiching," "Front-running," or inserting "Jit-liquidity" transactions that result in a worse execution price for a user than if the user's transaction had executed in isolation.
* **Permitted MEV:** Back-running (e.g., arbitrage that happens *after* a price update) is permitted as it stabilizes markets and does not harm the user's execution price.

### III. Self-Activation Compliance (The "Only Active When Active" Rule)
* **Violation:** Producing a block or posting a batch to L1 with a timestamp $t$ where `manager.isCurrentOperator(...)` returned `false`.
* **Rationale:** This enforces the rotation mechanics. A "zombie" sequencer confusing the network is a constitutional violation.

### IV. Liveness (The "99% Rule")
* **Violation:** Failing to produce blocks for more than **5 minutes** during the Operator's assigned epoch, absent an L1 outage or global OP Stack halt.

---

## 4. Evidence Standards

Challengers must submit evidence meeting the following standards.


### A. For Censorship Claims (The "Multi-Witness" Standard)
Censorship cannot be proven cryptographically, but it can be proven by corroboration. Jurors shall reject "screenshots" as standalone evidence.

* **Primary Evidence (Must provide at least one):**
    1.  **Provider Logs:** Raw JSON-RPC logs from reputable, independent RPC providers (e.g., Alchemy, Infura, QuickNode, Flashbots) showing the transaction was `PENDING` in their mempool at time $T$.
        * *Format:* Must include the request ID, timestamp, and full JSON response.
        * *Verification:* Challengers may be asked to provide an API key or session capability for Jurors to verify the log authenticity if disputed.
    2.  **Mempool Archives:** Links to historical mempool data services (e.g., bloXroute, Zeromev, or specific L2 mempool explorers) showing the transaction's ingress timestamp.

* **Corroborating Witness (The "Notary" Rule):**
    * If Provider Logs are unavailable, the Challenger may submit **Signed Attestations** from at least **2** unrelated, reputable entities (e.g., other Operators in this Registry, known Indexers, or recognized L2 Bridge operators).
    * *Attestation Content:* "I, [Entity Name], operating a node at [IP/ID], attest that I observed Transaction [Hash] in my local mempool at [Timestamp], prior to the production of Block [N]."
    * *Signature:* The message must be cryptographically signed by the entity's known public key (e.g., their registered Batcher key).

* **The "Trace" Requirement (Validity Proof):**
    * The Challenger must *also* provide a simulation (Trace) proving that if the transaction *had* been included in the blocks where it was missing, it would have **succeeded** (consumed gas and not reverted). This rules out "censorship" that was actually just the sequencer filtering out invalid txs.

### B. For MEV Claims (Simulation Proof)
Challengers must demonstrate **harm** to the user.
* **Required Evidence:**
    1.  **The Attack Bundle:** Identify the Victim Tx ($V$) and the Operator's Tx ($O$).
    2.  **State Delta:**
        * *Actual Execution:* $O$ executes before $V$. User receives $X$ tokens.
        * *Simulated Execution:* Run $V$ alone against the previous block state. User receives $Y$ tokens.
    3.  **Proof of Loss:** If $Y > X$ (User got less because of $O$), the violation is proven.
* **Attribution:** The Challenger must show $O$ is related to the Operator (e.g., benefits the same address, or is a known MEV bot allowed by the Operator). *Note: In a decentralized sequencer, the sequencer is liable for the blocks they sign, regardless of whether they "outsourced" building to a malicious builder.*

### C. For Unauthorized Production (Cryptographic Proof)
* **Required Evidence:**
    1.  **L1 Reference:** The L1 Transaction Hash where the batch was posted.
    2.  **Timestamp Mismatch:** A screenshot or Etherscan link showing the L1 block timestamp was outside the Operator's epoch.
