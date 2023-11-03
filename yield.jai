// @ToDO: Rename to something that makes at least some sense…
Async_Task :: struct {
    // Will be set before begin_work is called:
    wait_group: *Wait_Group;
    on_complete_data: *void;
    on_complete: Async_Task_Complete_Callback;


    // Functions that any Async_Task needs to set:
    begin_work: #type (task: *Async_Task); // Will be called from the wait_group’s thread
    cancel: #type (task: *Async_Task);

    // Optional;
    // If this is set, the context will be prepared with this request
    // before on_complete or begin_work is called
    request: *Request;
}

Async_Task_Complete_Callback :: #type (*Async_Task, data: *void);


begin :: (task: *Async_Task, wait_group: *Wait_Group, on_complete_data: *void, on_complete: Async_Task_Complete_Callback) {
    assert(task.begin_work != null);
    assert(task.cancel != null);
    task.wait_group = wait_group;
    task.on_complete_data = on_complete_data;
    task.on_complete = on_complete;
    if context.hyperserve.request && !task.request  {
        // log("Propagating request % to inner Async_Task…", context.hyperserve.request.id);
        task.request = context.hyperserve.request;
    }

    if task.request {
        push_allocator(pool_allocator_proc, task.request.pool);
        client := task.request.client;
        server := client.server;
        context.hyperserve.server = server;
        push_client(client);
        push_request(task.request);

        task.begin_work(task);
    } else {
        task.begin_work(task);
    }
}

// Call this from your task when it is done with its work.
// @ToDo: Rename to task_is_complete
on_complete :: (task: *Async_Task) {
    if task.request {
        push_allocator(pool_allocator_proc, task.request.pool);
        client := task.request.client;
        server := client.server;
        context.hyperserve.server = server;
        push_client(client);
        push_request(task.request);

        task.on_complete(task, task.on_complete_data);
    } else {
        task.on_complete(task, task.on_complete_data);
    }
}

// Intermediary function to test yielding. Not the final API.
// Waits until all tasks have signalled completion
debug_wait_for :: (tasks: .. *Async_Task) -> bool {
    wait_group: Wait_Group;
    init(*wait_group);
    defer deinit(*wait_group);

    active_tasks: [..] *Async_Task;
    array_add(*active_tasks, ..tasks);
    defer array_free(active_tasks);
    on_complete :: (task: *Async_Task, data: *void) {
        active_tasks := cast(*[..] *Async_Task) data;
        array_unordered_remove_by_value(active_tasks, task);
    }

	for task: tasks {
        begin(task, *wait_group, *active_tasks, on_complete);
	}

    while active_tasks {
        success := wait_for_events(*wait_group);
        if !success {
            to_cancel := array_copy(active_tasks); // because cancelling might modify the array via the on_complete callback
            defer array_free(to_cancel);
            for to_cancel {
                it.cancel(it);
            }
            assert(active_tasks.count == 0);
            // @ToDo: cleanup!
            return false;
        }
    }

	return true;
}
