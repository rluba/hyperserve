#import "Basic";
#import "Hash_Table";
#import "Random";
#import "String";
#import "Thread";

#import "hyperserve"()(Request_Extra = Request_State);
#import "wait_group";

main :: () {
    server: Server;
    server.verbose = .NONE;
    {
        success := add_route(*server, .GET, "/", index,   auth = .OFF);
        success &= add_route(*server, .GET, "/updates", updates, auth = .OFF);
        if !success exit(1);
    }

    PORT :: 8000;
    success := start(*server, port = PORT, num_threads = 4);
    if !success exit(1);
    defer deinit(*server);

    log("listening on port %", PORT);

    while server.state != .STOPPED {
        update(*server);
        reset_temporary_storage();
    }
}

index :: (request: *Request, parameters: *Request_Parameters()) {
    template :: #string END
<!doctype html><html>
  <head>
    <title>%1</title>
    <script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.7/bundles/datastar.js"></script>
  <body>
    <h2>%1</h2>
    <div data-init="@get('/updates')">Get Backend State</div>
    <div id="counter"></div>
  </body>
</html>
END

    body :: #run sprint(template, "Jai + Datastar Example");

    respond(body, content_type="text/html");
}

Request_State :: struct {
    counter    : int;
    phase      : Counter_Phase;
    session_id : string;
}

Counter_Phase :: enum {
    INIT;
    READY_TO_SEND;
    READY_TO_COUNT;
}

updates :: (request: *Request, parameters: *Request_Parameters()) {
    using request.extra;

    if #complete phase == {
      case .INIT;
        SSE_HEADERS := Response_Header.[
            .{ name  = "Cache-Control", value = "no-cache"   },
            .{ name  = "Connection",    value = "keep-alive" },
        ];

        if !begin_response(*request.response_builder, content_length = 0, status_code = 200, content_type = "text/event-stream", headers = SSE_HEADERS) {
            log_error("Could not send SSE headers");
            return;
        }
        flush();

        phase = .READY_TO_SEND;

      case .READY_TO_SEND;
        fragment := tprint("<div id=\"counter\">%</div>", counter);
        append_patch_elements_event(*request.response_builder, fragment);
        flush();

        phase = .READY_TO_COUNT;

      case .READY_TO_COUNT;
        if counter < 10 {
            counter += 1;

            phase = .READY_TO_SEND;

            // wait TIMEOUT_MS before sending the next event
            task := New(Timer_Task);
            request_yield(task);
        }
    }
}

LF :: "\n";

append_patch_elements_event :: (builder: *String_Builder, fragment: string) {
    append(builder, "event: datastar-patch-elements");
    append(builder, LF);

    for split(fragment, LF) {
        append(builder, tprint("data: elements %", it));
        append(builder, LF);
    }
    append(builder, LF);
}

Timer_Task :: struct {
    using #as base: Async_Task;
    base.begin_work = timer_task_begin_work;
    base.cancel     = timer_task_cancel;

    timer: User_Event_Id;
}

TIMEOUT_MS :: 1000;

timer_task_begin_work :: (task: *Async_Task) {
    timer_task := cast(*Timer_Task) task;

    success: bool;
    success, timer_task.timer = add_timer(timer_task.wait_group, timer_task, on_timer_timeout, TIMEOUT_MS, recurring = false);
    if !success {
        return;
    }
}

on_timer_timeout :: (group: *Wait_Group, handle: User_Event_Id, task: *Timer_Task) {
    on_complete(task);
}

timer_task_cancel :: (task: *Async_Task) {
    timer_task := cast(*Timer_Task) task;
    if timer_task.timer {
        remove_timer(task.wait_group, timer_task.timer);
    }
}
