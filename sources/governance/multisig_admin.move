/// Multi-Sig Admin — threshold-signature wrapper for all admin operations.
///
/// Wraps the protocol's AdminCap objects so that critical operations require
/// M-of-N signer approval before execution. Prevents single-key compromise
/// from granting full protocol control.
///
/// Flow:
///   1. Any signer calls `propose_action(...)` describing the admin operation
///   2. Other signers call `approve_action(...)` to add their approval
///   3. Once threshold is met, any signer calls `execute_action(...)` to run it
///   4. The action is marked executed and cannot be replayed
///
/// Actions expire after ACTION_EXPIRY_MS to prevent stale proposals lingering.
module crux::multisig_admin {

    use sui::clock::Clock;
    use sui::event;

    // ===== Error Codes =====

    const ENotSigner: u64 = 1200;
    const EAlreadyApproved: u64 = 1201;
    const EThresholdNotMet: u64 = 1202;
    const EActionAlreadyExecuted: u64 = 1203;
    const EActionExpired: u64 = 1204;
    const EInvalidThreshold: u64 = 1205;
    const EActionNotFound: u64 = 1206;
    const ETooManyPendingActions: u64 = 1207;
    const EDuplicateSigner: u64 = 1208;

    // ===== Constants =====

    /// Actions expire after 7 days if not executed
    const ACTION_EXPIRY_MS: u64 = 604_800_000;

    /// Maximum pending actions to prevent DoS
    const MAX_PENDING_ACTIONS: u64 = 100;

    // ===== Action Types =====
    // Each constant represents a different admin operation

    const ACTION_UPDATE_RATE: u8 = 0;
    const ACTION_SETTLE_MARKET: u8 = 1;
    const ACTION_SETTLE_TRANCHE: u8 = 2;
    const ACTION_SETTLE_SWAP: u8 = 3;
    const ACTION_PAUSE_VAULT: u8 = 4;
    const ACTION_UNPAUSE_VAULT: u8 = 5;
    const ACTION_PAUSE_POOL: u8 = 6;
    const ACTION_ADD_SIGNER: u8 = 7;
    const ACTION_REMOVE_SIGNER: u8 = 8;
    const ACTION_CHANGE_THRESHOLD: u8 = 9;

    // ===== Structs =====

    /// Shared object: the multi-sig controller that wraps admin authority.
    /// Holds the list of authorized signers and the approval threshold.
    public struct MultisigController has key {
        id: UID,
        /// Authorized signer addresses
        signers: vector<address>,
        /// Number of approvals required to execute an action
        threshold: u64,
        /// All pending (not yet executed) actions
        pending_actions: vector<PendingAction>,
        /// Monotonically increasing action ID
        next_action_id: u64,
    }

    /// A proposed admin action awaiting approvals.
    public struct PendingAction has store, drop, copy {
        action_id: u64,
        /// The type of admin operation (see ACTION_* constants)
        action_type: u8,
        /// Encoded parameters for the action (object IDs, amounts, etc.)
        /// Interpretation depends on action_type.
        target_id: ID,
        /// Numeric parameter (rate, amount, etc.)
        param_u128: u128,
        /// Address parameter (new signer, treasury, etc.)
        param_address: address,
        /// Who proposed this action
        proposer: address,
        /// When proposed (ms)
        proposed_ms: u64,
        /// Addresses that have approved
        approvals: vector<address>,
        /// Whether this action has been executed
        is_executed: bool,
    }

    // ===== Events =====

    public struct ActionProposed has copy, drop {
        action_id: u64,
        action_type: u8,
        proposer: address,
    }

    public struct ActionApproved has copy, drop {
        action_id: u64,
        approver: address,
        approval_count: u64,
        threshold: u64,
    }

    public struct ActionExecuted has copy, drop {
        action_id: u64,
        action_type: u8,
        executor: address,
    }

    public struct SignerAdded has copy, drop {
        signer: address,
        new_total: u64,
    }

    public struct SignerRemoved has copy, drop {
        signer: address,
        new_total: u64,
    }

    public struct ThresholdChanged has copy, drop {
        old_threshold: u64,
        new_threshold: u64,
    }

    // ===== Init =====

    /// Create the multisig controller. Called once at package deploy.
    /// The deployer is the initial sole signer with threshold 1.
    /// Additional signers and higher threshold should be set immediately after.
    fun init(ctx: &mut TxContext) {
        let deployer = ctx.sender();
        let controller = MultisigController {
            id: object::new(ctx),
            signers: vector[deployer],
            threshold: 1,
            pending_actions: vector[],
            next_action_id: 0,
        };
        transfer::share_object(controller);
    }

    // ===== Core Multi-Sig Operations =====

    /// Propose a new admin action. Only authorized signers can propose.
    /// Returns the action_id for reference.
    public fun propose_action(
        controller: &mut MultisigController,
        action_type: u8,
        target_id: ID,
        param_u128: u128,
        param_address: address,
        clock: &Clock,
        ctx: &TxContext,
    ): u64 {
        let proposer = ctx.sender();
        assert!(is_signer(controller, proposer), ENotSigner);
        assert!(controller.pending_actions.length() < MAX_PENDING_ACTIONS, ETooManyPendingActions);

        let action_id = controller.next_action_id;
        controller.next_action_id = action_id + 1;

        let action = PendingAction {
            action_id,
            action_type,
            target_id,
            param_u128,
            param_address,
            proposer,
            proposed_ms: clock.timestamp_ms(),
            approvals: vector[proposer], // Proposer auto-approves
            is_executed: false,
        };

        controller.pending_actions.push_back(action);

        event::emit(ActionProposed {
            action_id,
            action_type,
            proposer,
        });

        action_id
    }

    /// Approve a pending action. Each signer can approve once.
    public fun approve_action(
        controller: &mut MultisigController,
        action_id: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let approver = ctx.sender();
        assert!(is_signer(controller, approver), ENotSigner);

        let (found, idx) = find_action(controller, action_id);
        assert!(found, EActionNotFound);

        let action = &mut controller.pending_actions[idx];
        assert!(!action.is_executed, EActionAlreadyExecuted);
        assert!(clock.timestamp_ms() < action.proposed_ms + ACTION_EXPIRY_MS, EActionExpired);
        assert!(!has_approved(action, approver), EAlreadyApproved);

        action.approvals.push_back(approver);

        event::emit(ActionApproved {
            action_id,
            approver,
            approval_count: action.approvals.length(),
            threshold: controller.threshold,
        });
    }

    /// Check if an action has met the threshold and can be executed.
    public fun is_ready(controller: &MultisigController, action_id: u64): bool {
        let (found, idx) = find_action(controller, action_id);
        if (!found) return false;
        let action = &controller.pending_actions[idx];
        !action.is_executed && action.approvals.length() >= controller.threshold
    }

    /// Mark an action as executed. Only callable within the package.
    /// The actual execution logic lives in the calling module, which reads
    /// the action params and performs the admin operation.
    public(package) fun mark_executed(
        controller: &mut MultisigController,
        action_id: u64,
        clock: &Clock,
        ctx: &TxContext,
    ): (u8, ID, u128, address) {
        let executor = ctx.sender();
        assert!(is_signer(controller, executor), ENotSigner);

        let (found, idx) = find_action(controller, action_id);
        assert!(found, EActionNotFound);

        let action = &mut controller.pending_actions[idx];
        assert!(!action.is_executed, EActionAlreadyExecuted);
        assert!(clock.timestamp_ms() < action.proposed_ms + ACTION_EXPIRY_MS, EActionExpired);
        assert!(action.approvals.length() >= controller.threshold, EThresholdNotMet);

        action.is_executed = true;

        let action_type = action.action_type;
        let target_id = action.target_id;
        let param_u128 = action.param_u128;
        let param_address = action.param_address;

        event::emit(ActionExecuted {
            action_id,
            action_type,
            executor,
        });

        (action_type, target_id, param_u128, param_address)
    }

    // ===== Signer Management =====
    // These operations themselves require multi-sig approval.
    // The calling module proposes an ACTION_ADD_SIGNER / ACTION_REMOVE_SIGNER,
    // then executes it here after threshold is met.

    /// Add a new signer. Called by the execution layer after multi-sig approval.
    public(package) fun add_signer(controller: &mut MultisigController, new_signer: address) {
        // Check not already a signer
        let mut i = 0u64;
        let len = controller.signers.length();
        while (i < len) {
            assert!(controller.signers[i] != new_signer, EDuplicateSigner);
            i = i + 1;
        };
        controller.signers.push_back(new_signer);

        event::emit(SignerAdded {
            signer: new_signer,
            new_total: controller.signers.length(),
        });
    }

    /// Remove a signer. Threshold must remain achievable.
    public(package) fun remove_signer(controller: &mut MultisigController, signer: address) {
        let mut i = 0u64;
        let len = controller.signers.length();
        let mut found = false;
        while (i < len) {
            if (controller.signers[i] == signer) {
                controller.signers.remove(i);
                found = true;
                break
            };
            i = i + 1;
        };
        assert!(found, ENotSigner);

        // Ensure threshold is still achievable
        assert!(controller.signers.length() >= controller.threshold, EInvalidThreshold);

        event::emit(SignerRemoved {
            signer,
            new_total: controller.signers.length(),
        });
    }

    /// Change the approval threshold.
    public(package) fun change_threshold(controller: &mut MultisigController, new_threshold: u64) {
        assert!(new_threshold > 0, EInvalidThreshold);
        assert!(new_threshold <= controller.signers.length(), EInvalidThreshold);

        let old = controller.threshold;
        controller.threshold = new_threshold;

        event::emit(ThresholdChanged {
            old_threshold: old,
            new_threshold,
        });
    }

    // ===== View Functions =====

    /// Get the current signer list.
    public fun signers(controller: &MultisigController): &vector<address> {
        &controller.signers
    }

    /// Get the current threshold.
    public fun threshold(controller: &MultisigController): u64 {
        controller.threshold
    }

    /// Get the number of pending (non-executed) actions.
    public fun pending_count(controller: &MultisigController): u64 {
        let mut count = 0u64;
        let mut i = 0u64;
        let len = controller.pending_actions.length();
        while (i < len) {
            if (!controller.pending_actions[i].is_executed) {
                count = count + 1;
            };
            i = i + 1;
        };
        count
    }

    /// Get action details: (action_type, approval_count, is_executed, proposer)
    public fun action_details(
        controller: &MultisigController,
        action_id: u64,
    ): (u8, u64, bool, address) {
        let (found, idx) = find_action(controller, action_id);
        assert!(found, EActionNotFound);
        let a = &controller.pending_actions[idx];
        (a.action_type, a.approvals.length(), a.is_executed, a.proposer)
    }

    // ===== Action Type Constants (public for callers) =====

    public fun action_type_update_rate(): u8 { ACTION_UPDATE_RATE }
    public fun action_type_settle_market(): u8 { ACTION_SETTLE_MARKET }
    public fun action_type_settle_tranche(): u8 { ACTION_SETTLE_TRANCHE }
    public fun action_type_settle_swap(): u8 { ACTION_SETTLE_SWAP }
    public fun action_type_pause_vault(): u8 { ACTION_PAUSE_VAULT }
    public fun action_type_unpause_vault(): u8 { ACTION_UNPAUSE_VAULT }
    public fun action_type_pause_pool(): u8 { ACTION_PAUSE_POOL }
    public fun action_type_add_signer(): u8 { ACTION_ADD_SIGNER }
    public fun action_type_remove_signer(): u8 { ACTION_REMOVE_SIGNER }
    public fun action_type_change_threshold(): u8 { ACTION_CHANGE_THRESHOLD }

    // ===== Internal Helpers =====

    fun is_signer(controller: &MultisigController, addr: address): bool {
        let mut i = 0u64;
        let len = controller.signers.length();
        while (i < len) {
            if (controller.signers[i] == addr) return true;
            i = i + 1;
        };
        false
    }

    fun has_approved(action: &PendingAction, addr: address): bool {
        let mut i = 0u64;
        let len = action.approvals.length();
        while (i < len) {
            if (action.approvals[i] == addr) return true;
            i = i + 1;
        };
        false
    }

    fun find_action(controller: &MultisigController, action_id: u64): (bool, u64) {
        let mut i = 0u64;
        let len = controller.pending_actions.length();
        while (i < len) {
            if (controller.pending_actions[i].action_id == action_id) {
                return (true, i)
            };
            i = i + 1;
        };
        (false, len)
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
