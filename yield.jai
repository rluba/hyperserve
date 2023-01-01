Yiealdable :: struct {
    yielded_on: [..] *Yield_Reason;

}
Yield_Reason_Complete_Callback :: #type (*Yield_Reason);

Yield_Reason :: struct {
    target: *Yiealdable;

    add_to_wait_group: #type (reason: *Yield_Reason, wait_group: *Wait_Group, on_complete: Yield_Reason_Complete_Callback);
    cancel: #type (reason: *Yield_Reason, wait_group: *Wait_Group);
}
