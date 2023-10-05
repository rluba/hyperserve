// @ToDO: Rename to something that makes at least some sense…
// @ToDo: Rename to Async_Work?
Yield_Reason :: struct {
    // Will be set before begin_work is called:
    wait_group: *Wait_Group;
    on_complete_data: *void;
    on_complete: Yield_Reason_Complete_Callback;

    // Functions that any Yield_Reason needs to set:
    begin_work: #type (reason: *Yield_Reason);
    cancel: #type (reason: *Yield_Reason);
}

Yield_Reason_Complete_Callback :: #type (*Yield_Reason, data: *void);


begin :: (reason: *Yield_Reason, wait_group: *Wait_Group, on_complete_data: *void, on_complete: Yield_Reason_Complete_Callback) {
    assert(reason.begin_work != null);
    assert(reason.cancel != null);
    reason.wait_group = wait_group;
    reason.on_complete_data = on_complete_data;
    reason.on_complete = on_complete;
    reason.begin_work(reason);
}

on_complete :: (reason: *Yield_Reason) {
    reason.on_complete(reason, reason.on_complete_data);
}

// Intermediary function to test yielding. Not the final API.
// Waits until all reasons have signalled completion
// @ToDo: add timeout
wait_for :: (reasons: .. *Yield_Reason) -> bool {
    wait_group: Wait_Group;
    init(*wait_group);
    defer deinit(*wait_group);

    active_reasons: [..] *Yield_Reason;
    array_add(*active_reasons, ..reasons);
    defer array_free(active_reasons);
    on_complete :: (reason: *Yield_Reason, data: *void) {
        active_reasons := cast(*[..] *Yield_Reason) data;
        array_unordered_remove_by_value(active_reasons, reason);
    }

	for reason: reasons {
        begin(reason, *wait_group, *active_reasons, on_complete);
	}

    while active_reasons {
        success := wait_for_events(*wait_group);
        if !success {
            to_cancel := array_copy(active_reasons); // because cancelling might modify the array via the on_complete callback
            defer array_free(to_cancel);
            for to_cancel {
                it.cancel(it);
            }
            assert(active_reasons.count == 0);
            // @ToDo: cleanup!
            return false;
        }
    }

	return true;
}

