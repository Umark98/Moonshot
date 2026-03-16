module crux::governor {
    use sui::clock::Clock;
    use sui::event;

    // ===== Error Codes =====
    const EProposalNotFound: u64 = 950;
    const EProposalExpired: u64 = 951;
    const EProposalNotReady: u64 = 952;
    const EAlreadyVoted: u64 = 953;
    const EAlreadyExecuted: u64 = 954;
    const EVotingNotEnded: u64 = 955;
    const EQuorumNotReached: u64 = 956;
    const EProposalDefeated: u64 = 957;

    // ===== Governance Parameters =====
    const VOTING_PERIOD_MS: u64 = 259_200_000;   // 3 days
    const TIMELOCK_MS: u64 = 172_800_000;         // 2 days
    const QUORUM_VOTES: u64 = 100_000;            // Minimum votes for quorum

    // ===== Proposal State Constants =====
    const STATE_ACTIVE: u8 = 0;
    #[allow(unused_const)]
    const STATE_DEFEATED: u8 = 1;
    #[allow(unused_const)]
    const STATE_SUCCEEDED: u8 = 2;
    const STATE_QUEUED: u8 = 3;
    const STATE_EXECUTED: u8 = 4;
    const STATE_CANCELLED: u8 = 5;

    // ===== Structs =====

    public struct GovernorAdminCap has key, store {
        id: UID,
    }

    public struct GovernorState has key {
        id: UID,
        proposals: vector<Proposal>,
        next_proposal_id: u64,
        total_proposals: u64,
    }

    public struct Proposal has store, drop, copy {
        proposal_id: u64,
        proposer: address,
        description: vector<u8>,
        votes_for: u64,
        votes_against: u64,
        start_ms: u64,
        end_ms: u64,
        execution_ms: u64,
        state: u8,
        voters: vector<address>,
    }

    // ===== Events =====

    public struct ProposalCreated has copy, drop {
        proposal_id: u64,
        proposer: address,
        description: vector<u8>,
        start_ms: u64,
        end_ms: u64,
    }

    public struct VoteCast has copy, drop {
        proposal_id: u64,
        voter: address,
        support: bool,
        vote_weight: u64,
    }

    public struct ProposalExecuted has copy, drop {
        proposal_id: u64,
    }

    public struct ProposalCancelled has copy, drop {
        proposal_id: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let admin_cap = GovernorAdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, ctx.sender());

        let state = GovernorState {
            id: object::new(ctx),
            proposals: vector[],
            next_proposal_id: 0,
            total_proposals: 0,
        };
        transfer::share_object(state);
    }

    // ===== Public Functions =====

    /// Create a new proposal. Returns the proposal ID.
    public fun create_proposal(
        state: &mut GovernorState,
        description: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        let now = clock.timestamp_ms();
        let proposal_id = state.next_proposal_id;
        let end_ms = now + VOTING_PERIOD_MS;

        let proposal = Proposal {
            proposal_id,
            proposer: ctx.sender(),
            description,
            votes_for: 0,
            votes_against: 0,
            start_ms: now,
            end_ms,
            execution_ms: end_ms + TIMELOCK_MS,
            state: STATE_ACTIVE,
            voters: vector[],
        };

        state.proposals.push_back(proposal);
        state.next_proposal_id = proposal_id + 1;
        state.total_proposals = state.total_proposals + 1;

        event::emit(ProposalCreated {
            proposal_id,
            proposer: ctx.sender(),
            description,
            start_ms: now,
            end_ms,
        });

        proposal_id
    }

    /// Cast a vote on an active proposal.
    public fun cast_vote(
        state: &mut GovernorState,
        proposal_id: u64,
        support: bool,
        vote_weight: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let idx = find_proposal_index(state, proposal_id);
        assert!(idx < state.proposals.length(), EProposalNotFound);

        let proposal = &mut state.proposals[idx];
        let now = clock.timestamp_ms();

        assert!(proposal.state == STATE_ACTIVE, EProposalExpired);
        assert!(now >= proposal.start_ms && now <= proposal.end_ms, EProposalExpired);

        let voter = ctx.sender();
        assert!(!has_voted(proposal, voter), EAlreadyVoted);

        if (support) {
            proposal.votes_for = proposal.votes_for + vote_weight;
        } else {
            proposal.votes_against = proposal.votes_against + vote_weight;
        };

        proposal.voters.push_back(voter);

        event::emit(VoteCast {
            proposal_id,
            voter,
            support,
            vote_weight,
        });
    }

    /// Queue a proposal after voting has ended and it has succeeded.
    public fun queue_proposal(
        state: &mut GovernorState,
        proposal_id: u64,
        clock: &Clock,
    ) {
        let idx = find_proposal_index(state, proposal_id);
        assert!(idx < state.proposals.length(), EProposalNotFound);

        let proposal = &mut state.proposals[idx];
        let now = clock.timestamp_ms();

        assert!(proposal.state == STATE_ACTIVE, EAlreadyExecuted);
        assert!(now > proposal.end_ms, EVotingNotEnded);

        let total_votes = proposal.votes_for + proposal.votes_against;
        assert!(total_votes >= QUORUM_VOTES, EQuorumNotReached);
        assert!(proposal.votes_for > proposal.votes_against, EProposalDefeated);

        proposal.state = STATE_QUEUED;
    }

    /// Execute a proposal after the timelock has elapsed.
    public fun execute_proposal(
        state: &mut GovernorState,
        proposal_id: u64,
        clock: &Clock,
    ) {
        let idx = find_proposal_index(state, proposal_id);
        assert!(idx < state.proposals.length(), EProposalNotFound);

        let proposal = &mut state.proposals[idx];
        let now = clock.timestamp_ms();

        assert!(proposal.state == STATE_QUEUED, EProposalNotReady);
        assert!(now >= proposal.execution_ms, EProposalNotReady);

        proposal.state = STATE_EXECUTED;

        event::emit(ProposalExecuted {
            proposal_id,
        });
    }

    /// Admin-only: cancel a proposal.
    public fun cancel_proposal(
        _admin: &GovernorAdminCap,
        state: &mut GovernorState,
        proposal_id: u64,
    ) {
        let idx = find_proposal_index(state, proposal_id);
        assert!(idx < state.proposals.length(), EProposalNotFound);

        let proposal = &mut state.proposals[idx];
        assert!(proposal.state != STATE_EXECUTED, EAlreadyExecuted);

        proposal.state = STATE_CANCELLED;

        event::emit(ProposalCancelled {
            proposal_id,
        });
    }

    // ===== View Functions =====

    /// Get a copy of a proposal by ID.
    public fun get_proposal(state: &GovernorState, proposal_id: u64): Proposal {
        let idx = find_proposal_index(state, proposal_id);
        assert!(idx < state.proposals.length(), EProposalNotFound);
        state.proposals[idx]
    }

    /// Get the state of a proposal by ID.
    public fun proposal_state(state: &GovernorState, proposal_id: u64): u8 {
        let idx = find_proposal_index(state, proposal_id);
        assert!(idx < state.proposals.length(), EProposalNotFound);
        state.proposals[idx].state
    }

    /// Get the total number of proposals.
    public fun proposal_count(state: &GovernorState): u64 {
        state.total_proposals
    }

    // ===== Internal Helpers =====

    /// Find the index of a proposal by its ID. Returns vector length if not found.
    fun find_proposal_index(state: &GovernorState, proposal_id: u64): u64 {
        let mut i = 0;
        let len = state.proposals.length();
        while (i < len) {
            if (state.proposals[i].proposal_id == proposal_id) {
                return i
            };
            i = i + 1;
        };
        len
    }

    /// Check whether an address has already voted on a proposal.
    fun has_voted(proposal: &Proposal, voter: address): bool {
        let mut i = 0;
        let len = proposal.voters.length();
        while (i < len) {
            if (proposal.voters[i] == voter) {
                return true
            };
            i = i + 1;
        };
        false
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
