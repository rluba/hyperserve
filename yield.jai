Yieldable :: struct {
    yielded_on: [..] *Yield_Reason;
}

Yield_Reason_Complete_Callback :: #type (*Yield_Reason);

Yield_Reason :: struct {
    target: *Yieldable;

    add_to_wait_group: #type (reason: *Yield_Reason, wait_group: *Wait_Group, on_complete: Yield_Reason_Complete_Callback);
    cancel: #type (reason: *Yield_Reason, wait_group: *Wait_Group);
}

// Intermediary function to test yielding. Not the final API.
// Waits until all reasons have signalled completion
// @ToDo: add timeout
wait_for :: (reasons: .. *Yield_Reason) -> bool {
    wait_group: Wait_Group;
    init(*wait_group);
    defer deinit(*wait_group);

    yieldable: Yieldable;
    array_add(*yieldable.yielded_on, ..reasons);
    array_free(yieldable.yielded_on);
    on_complete :: (reason: *Yield_Reason) {
        array_unordered_remove_by_value(*reason.target.yielded_on, reason);
    }

	for reason: reasons {
        reason.target = *yieldable;
        reason.add_to_wait_group(reason, *wait_group, on_complete);
	}

    while yieldable.yielded_on {
        success := wait_for_events(*wait_group);
        if !success {
            to_cancel := array_copy(yieldable.yielded_on); // because cancelling might modify the array via the on_complete callback
            defer array_free(to_cancel);
            for to_cancel {
                it.cancel(it, *wait_group);
            }
            assert(yieldable.yielded_on.count == 0);
            // @ToDo: cleanup!
            return false;
        }
    }

	return true;
}

