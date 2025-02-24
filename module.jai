// @ToDo:
// - Decode bodies (JSON, multipart, …)
// - Declare the accepted content types for body parsing as route options
// - Offer option to stream the body instead of decoding it?
// - Add option to limit body size
// - Offer more response options (custom headers, …)
// - Support for transfer-encoding: chunked
// - handle Http_Method.OPTIONS correctlty
// - Add timeouts for clients: after connect, after first byte, ...
// …

#module_parameters () (Request_Extra: Type = struct {}, USE_CLUSTER := false);

#if !USE_CLUSTER {
    // Address definitions from cluster
    Address_Type :: enum u8 {
        IPV4 :: 4;
        IPV6 :: 6;
    }

    Address :: union {
        v4: u32;
        v6: [16] u8;
    }

    Socket_Address :: struct {
        type:    Address_Type;
        port:    u16;
        address: Address;
    }

    socket_address :: (addr: sockaddr_in) -> Socket_Address {
        result: Socket_Address;
        result.type = .IPV4;
        result.port = addr.sin_port;
        #if OS == .WINDOWS {
            result.address.v4 = ntohl(addr.sin_addr.S_un.S_addr);
        } else {
            result.address.v4 = ntohl(addr.sin_addr.s_addr);
        }
        return result;
    }

    socket_address :: (addr: sockaddr_in6) -> Socket_Address {
        result: Socket_Address;
        result.type = .IPV6;
        result.port = addr.sin6_port;
        #if OS == .WINDOWS {
            result.address.v6 = addr.sin6_addr.u.Byte;
        } else #if OS == .MACOS {
            result.address.v6 = addr.sin6_addr.__u6_addr.__u6_addr8;
        } else #if OS == .LINUX {
            result.address.v6 = addr.sin6_addr.__in6_u.__u6_addr8;
        } else {
            #assert(false, "Unsupported OS");
        }
        return result;
    }

    format_address :: (type: Address_Type, address: Address) -> string {
        builder: String_Builder;
        append(*builder, type, address);
        return builder_to_string(*builder);
    }

    format_address :: (address: Socket_Address) -> string {
        builder: String_Builder;
        append(*builder, address.type, address.address);
        print_to_builder(*builder, ":%", address.port);
        return builder_to_string(*builder);
    }

    append :: (builder: *String_Builder, type: Address_Type, address: Address) {
        if #complete type == {
            case .IPV4; append_address(builder, address.v4);
            case .IPV6; append_address(builder, address.v6);
        }
    }
}

HANDLE_INVALID     :: -1;

RECEIVE_HEADER_TIMEOUT_MS :: 30_000; // ToDo: Make this configurable
RECEIVE_BODY_TIMEOUT_MS   :: 30_000; // ToDo: Make this configurable
SEND_TIMEOUT_MS           :: 30_000; // ToDo: Make this configurable

Auth_Callback :: #type (request: *Request, is_last_method: bool);

Verbosity :: enum_flags {
    NONE    :: 0x00;
    NORMAL  :: 0x01;
    TRAFFIC :: 0x02;
    THREADS :: 0x04;
}

Server :: struct {
    verbose                     := Verbosity.NONE;

    // @ToDo: Make overridable per route
    default_auth_methods:       [..] Auth_Callback; // Will be called in sequence from a request thread to do authentication. Can yield on Async_Tasks. Must call proceed_request_past_authentication() to signal success.
    routes:                     Table(Http_Method, Routing_Node);

    socket:                     s32 = HANDLE_INVALID;
    wait_group:                 Wait_Group;

    state: enum {
        DEFAULT;
        STARTED;
        STOPPING;
        STOPPED;
    };
    clients:                    Bucket_Array(Client, 64);

    request_thread_group:       Thread_Group;
    request_step_done_read_handle:   s32 = HANDLE_INVALID;
    request_step_done_write_handle:  s32 = HANDLE_INVALID;

    // Set this function if you need to to run custom initialization code
    // before a worker threads gets started (eg. for setting up custom context fields)
    init_thread_callback:       #type (thread: *Thread);
    request_completed_callback: #type (timestamp: Apollo_Time, duration_us: s64, request: *Request);

    open_connections:           int;

    requests_that_have_yielded: [..] *Request; // Just for debugging, for now
}

Client :: struct {
    server:               *Server;
    name:                 string;
    socket:               s32 = HANDLE_INVALID;
    address:              Socket_Address;

    receive_timer:        User_Event_Id;

    next_request_index:   int;

    waiting_for_data:     bool;
    received_eof:         bool;
    remove_after_request: bool;

    // Request data
    request_pool:         *Pool;
    request_start_time:   Apollo_Time = APOLLO_TIME_INVALID;
    pending_data:         String_Builder;
    header_end_offsets:   [..] int;
    was_cr:               bool;
    num_pending_newlines: int;
}

Base_Request :: struct {
    client:               *Client;
    pool:                 *Pool;
    id:                   string;
    header_data:          string;

    phase:                Request_Phase;
    next_auth_method_index := 0;
    yielded_on:           [..] *Async_Task;

    method:               Http_Method;
    url:                  string;
    http_version:         string;

    target:               string; // url minus protocol, server, port
    path:                 string;   // target without query part

    headers:              Table(string, string); // @ToDo: Add abstraction for on-the-fly decoding of encoded values?
    host:                 string;
    authorization:        string;
    content_length:       int;
    content_type:         string;
    cookies:              [..] Cookie;
    // @ToDo: More fields for commonly referenced headers

    pending_body:         String_Builder;

    // Internal framework fields for state tracking
    start_time:           Apollo_Time = APOLLO_TIME_INVALID;
    response_status_code: Status_Code;
    response_builder:     String_Builder;

    aborted_response:     bool;

    route:                Route; // Could be a pointer, if we’re sure that the routing table never changes…
    parsed_parameters:    *void;

    // // @ToDo: Make polymorphic on data and auto-new it before passing the request to the handler
    handler_data:         *void;
}

Cookie :: struct {
    name:  string;
    value: string;
}

Response_Header :: struct {
    name:  string;
    value: string;
}

// returns "" if the header was not set.
get_header_value :: (request: *Base_Request, header_name: string) -> string, found: bool {
    value_pointer := table_find_pointer(*request.headers, header_name);
    if !value_pointer return "", false;
    return <<value_pointer, true;
}

Request :: struct {
    using #as base: Base_Request;
    extra: Request_Extra;
}

Request_Phase :: enum {
    PARSING;
    AUTH;
    HANDLING;
    SENDING_RESPONSE;
}

HTTP_1_0 :: "HTTP/1.0";
HTTP_1_1 :: "HTTP/1.1";

Hyperserve_Context :: struct {
    server:  *Server;
    client:  *Client;
    request: *Request;
}

#add_context hyperserve: Hyperserve_Context;

Http_Method :: enum {
    GET;
    POST;
    PUT;
    DELETE;
    PATCH;
    HEAD;
    OPTIONS;
}

deinit :: (using server: *Server) {
    if request_thread_group.initted && !request_thread_group.should_exit {
        shutdown(*request_thread_group);
    }

    for * clients {
        remove_client(server, it);
    }

    deinit(*wait_group);

    close_and_reset(*socket);
    close_and_reset(*request_step_done_read_handle);
    close_and_reset(*request_step_done_write_handle);
}

start :: (server: *Server, port: u16, num_threads: s32 = 10) -> bool {
    #if USE_CLUSTER {
        if !cluster_init() return false;
    }

    result: s32;
    #if USE_CLUSTER {
        address: Address;
        #assert(size_of(type_of(in6addr_any)) == size_of(type_of(address.v6)));
        memcpy(address.v6.data, *in6addr_any, size_of(type_of(address.v6)));
        server.socket = cluster_listen(.IPV6, address, port);
        if server.socket == HANDLE_INVALID {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t create socket: % %", error_code, error_string);
            return false;
        }
    } else {
        // @ToDo: optionally restrict interface
        server.socket = socket(AF_INET6, .STREAM, 0);
        if server.socket == HANDLE_INVALID {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t create socket: % %", error_code, error_string);
            return false;
        }

        one: s32 = 1;
        zero: s32 = 0;
        result = setsockopt(server.socket, SOL_SOCKET, SO_REUSEADDR, *one, size_of(type_of(one)));
        if result == -1 {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t set socket option SO_REUSEADDR: % %", error_code, error_string);
            deinit(server);
            return false;
        }

        result = setsockopt(server.socket, SOL_IPV6, IPV6_V6ONLY, *zero, size_of(type_of(zero)));
        if result == -1 {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t set socket option IPV6_V6ONLY: % %", error_code, error_string);
            deinit(server);
            return false;
        }

        address: [16] u8;
        #assert(size_of(type_of(in6addr_any)) == size_of(type_of(address)));
        memcpy(address.data, *in6addr_any, size_of(type_of(address)));
        result = bind(server.socket, address, port);
        if result == -1 {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t bind socket: % %", error_code, error_string);
            deinit(server);
            return false;
        }

        result = listen(server.socket, SOMAXCONN);
        if result == -1 {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t listen on socket: % %", error_code, error_string);
            deinit(server);
            return false;
        }
    }

    success := set_blocking(server.socket, false);
    if !success {
        error_code := get_last_socket_error();
        error_string := System.get_error_string(error_code);
        log_error("Couldn’t set socket to non-blocking: % %", error_code, error_string);
        deinit(server);
        return false;
    }

    success = init(*server.wait_group, verbose = false);
    if !success {
        deinit(server);
        return false;
    }

    success = add_handles(*server.wait_group, server, handle_connect_event, server.socket);
    if !success {
        deinit(server);
        return false;
    }

    worker_pipes:          [2] s32;
    result = pipe(*worker_pipes);
    if result != 0 {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Could not create worker pipe: % %", error_code, error_string);
        return false;
    }

    server.request_step_done_read_handle  = worker_pipes[0];
    server.request_step_done_write_handle = worker_pipes[1];

    success = add_handles(*server.wait_group, server, handle_request_step_done_event, server.request_step_done_read_handle);
    if !success {
        deinit(server);
        return false;
    }

    // Instead of ignoring, we have to define a no-op signal handler because SIG_IGN is inherited by child processes, but signal handlers are not.
    // WTF, fork(), really?!?!
    ignore_signal :: (signal: s32) #c_call {}
    sa: sigaction_t;
    sa.sa_handler = ignore_signal;
    sigemptyset(*sa.sa_mask);
    sa.sa_flags = SA_ONSTACK | SA_RESTART;
    sigaction(SIGINT, *sa, null);  // Stop
    sigaction(SIGTERM, *sa, null); // Stop

    success = add_signals(*server.wait_group, server, handle_signal_event, SIGINT, SIGTERM);
    if !success {
        deinit(server);
        return false;
    }


    init_request_thread_group(server, num_threads);

    return true;
}

stop :: (using server: *Server, graceful := true) {
    if graceful && server.state == .STARTED {
        server.state = .STOPPING;
    } else {
        server.state = .STOPPED;
    }

    log("Disconnecting % clients…", server.clients.count);
    for * server.clients {
        it.remove_after_request = true;
    }

    if server.socket != -1 {
        success := remove_handle(*server.wait_group, server.socket);
        if !success {
            log_error("Could not remove server socket from wait group");
        }
        close_and_reset(*server.socket);
    }
}

Status_Code :: enum u16 {
    AUTO                            :: 0;
    // @Incomplete
    OK                              :: 200;
    CREATED                         :: 201;
    ACCEPTED                        :: 202;
    NO_CONTENT                      :: 204;
    PARTIAL_CONTENT                 :: 206;

    MOVED_PERMANENTLY               :: 301;
    FOUND                           :: 302;
    SEE_OTHER                       :: 303;
    NOT_MODIFIED                    :: 304;
    TEMPORARY_REDIRECT              :: 307;
    PERMANENT_REDIRECT              :: 308;

    BAD_REQUEST                     :: 400;
    UNAUTHORIZED                    :: 401;
    FORBIDDEN                       :: 403;
    NOT_FOUND                       :: 404;
    METHOD_NOT_ALLOWED              :: 405;
    CONFLICT                        :: 409;
    PAYLOAD_TOO_LARGE               :: 413;
    UNSUPPORTED_MEDIA_TYPE          :: 415;
    UNPROCESSABLE_ENTITY            :: 422;
    BAD_DATA                        :: UNPROCESSABLE_ENTITY;
    REQUEST_HEADER_FIELDS_TOO_LARGE :: 431;

    INTERNAL_SERVER_ERROR           :: 500;
    NOT_IMPLEMENTED                 :: 501;
    HTTP_VERSION_NOT_SUPPORTED      :: 505;
}

code :: (status_code: u16) -> Status_Code {
    return xx status_code;
}

update :: (using server: *Server) -> bool {
    success := wait_for_events(*wait_group);
    if !success {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Couldn’t wait for events. Exiting…");
        stop(server, graceful = false);
    }

    if state == .STOPPING {
        if open_connections == 0 {
            log("No more open connections during shutdown. Server has stopped.");
            state = .STOPPED;
        } else {
            log("Waiting for % open connections to close…", open_connections);
        }
    }

    return state == .STOPPED;
}

redirect :: (target_url: string, status_code := Status_Code.SEE_OTHER) {
    respond(.[], status_code = status_code, content_type = "text/plain", headers = .[.{"location", target_url}]);
}

// :ResponseHeaderValues:
respond :: (response := "", status_code := Status_Code.AUTO, content_type := "text/plain", headers: [] Response_Header = .[]) {
    respond(cast([] u8) response, status_code, content_type);
}

// :ResponseHeaderValues:
respond :: (response: [] u8, status_code := Status_Code.AUTO, content_type := "text/plain", headers: [] Response_Header = .[]) {
    using context.hyperserve;

    success := begin_response(*request.response_builder, response.count, status_code, content_type, headers);
    if !success return;

    append(*request.response_builder, cast(string) response);

    start_sending_response();
}

// :ResponseHeaderValues:
respond :: (response_builder: *String_Builder, status_code := Status_Code.AUTO, content_type := "text/plain", headers: [] Response_Header = .[]) {
    using context.hyperserve;

    content_length := builder_string_length(response_builder);

    builder: String_Builder;
    success := begin_response(*request.response_builder, content_length, status_code, content_type, headers);
    if !success return;

    append_and_steal_buffers(*request.response_builder, response_builder);

    start_sending_response();
}

// Any values in "headers" must be valid HTTP headers and be already quoted/escaped, if necessary! :ResponseHeaderValues:
begin_response :: (builder: *String_Builder, content_length: s64, status_code: Status_Code, content_type: string, headers: [] Response_Header = .[]) -> bool {
    using context.hyperserve;

    status_code_to_send := status_code;
    if status_code == .AUTO {
        if content_length {
            status_code_to_send = .OK;
        } else {
            status_code_to_send = .NO_CONTENT;
        }
    }

    if request.response_status_code {
        log_error("Trying to send a response to request %, but a % response was already sent!", request.id, request.response_status_code);
        return false;
    }

    request.response_status_code = status_code_to_send;

    // @ToDo: Maybe keep track of the HTTP version that was send and use the same version in the response?
    print_to_builder(builder, "% % %\r\n", request.http_version, cast(int) status_code_to_send, get_reason_string(status_code_to_send));
    print_to_builder(builder, "content-type: %; charset=utf-8\r\n", content_type);
    if request.http_version == HTTP_1_0 && client.remove_after_request == false {
        append(builder, "connection: keep-alive\r\n");
    }
    if request.http_version == HTTP_1_1 && client.remove_after_request == true {
        append(builder, "connection: close\r\n");
    }

    has_size_header := false;
    for headers {
        if contains_any_character(it.value, "\r\n") {
            return false;
        }

        print_to_builder(builder, "%: %\r\n", it.name, it.value);
        lower_name := to_lower_copy(it.name,, temp);
        if lower_name == {
            case "content-length"; #through;
            case "transfer-encoding";
                has_size_header = true;
        }
    }

    if !has_size_header {
        print_to_builder(builder, "content-length: %\r\n", content_length);
    }

    append(builder, "\r\n");
    return true;
}

start_sending_response :: () {
    using context.hyperserve;

    if server.verbose & .TRAFFIC {
        log("Responding with:\n%", builder_to_string(*request.response_builder, do_reset = false));
    }

    task := New(Sending_Task);
    task.current_response_buffer = get_base_buffer(*request.response_builder);
    task.current_response_buffer_offset = 0;

    request.phase = .SENDING_RESPONSE;
    request_yield(task);
}

Sending_Task :: struct {
    using #as base: Async_Task;
    base.begin_work = sending_task_begin_work;
    base.cancel     = sending_task_cancel;

    sending_start_time:             Apollo_Time;
    timer:                          User_Event_Id;
    current_response_buffer:        *String_Builder.Buffer;
    current_response_buffer_offset: s64;
    total_bytes_sent:               s64;
}

sending_task_begin_work :: (task: *Async_Task) {
    using context.hyperserve;

    sending := cast(*Sending_Task) task;

    success := add_handles(sending.wait_group, sending, can_send_data_event, request.client.socket, event_type = .WRITE);
    if !success {
        finalize_sending_task(sending, abort = true);
        return;
    }
    success, sending.timer = add_timer(sending.wait_group, sending, on_send_timeout, SEND_TIMEOUT_MS, recurring = false);
    if !success {
        finalize_sending_task(sending, abort = true);
        return;
    }
}

sending_task_cancel :: (task: *Async_Task) {
    sending := cast(*Sending_Task) task;
    finalize_sending_task(sending, abort = true);
}

can_send_data_event :: (group: *Wait_Group, handle: s32, is_eof: bool, event_type: Wait_Event_Type, task: *Sending_Task) {
    assert(event_type == .WRITE);
    request := task.request;
    push_allocator(pool_allocator_proc, request.pool);
    client := request.client;
    socket := request.client.socket;

    flags: MSG;
    #if OS == .LINUX {
        flags |= .NOSIGNAL;
    }

    while task.current_response_buffer {
        data := get_buffer_data(task.current_response_buffer) + task.current_response_buffer_offset;
        remaining := task.current_response_buffer.count - task.current_response_buffer_offset;
        while remaining {
            result := send(socket, data, cast(u64) remaining, flags);
            if result == -1 {
                error_code := get_last_socket_error();
                if error_code == EAGAIN || error_code == EWOULDBLOCK {
                    return; // Wait until we’re called again, when there’s more room.
                }

                error_string := System.get_error_string(error_code);
                log_error("Could not send response (after % bytes already sent): % %", task.total_bytes_sent, error_code, error_string);
                finalize_sending_task(task, abort = true);
                return;
            }

            assert(result <= remaining);
            data += result;
            task.current_response_buffer_offset += result;
            remaining -= result;
            task.total_bytes_sent += result;
        }

        task.current_response_buffer = task.current_response_buffer.next;
        task.current_response_buffer_offset = 0;
    }

    finalize_sending_task(task, abort = false);
}

on_send_timeout :: (group: *Wait_Group, handle: User_Event_Id, task: *Sending_Task) {
    finalize_sending_task(task, abort = true);
}

finalize_sending_task :: (task: *Sending_Task, abort: bool) {
    request := task.request;

    remove_handle(task.wait_group, request.client.socket, event_type = .WRITE);
    if task.timer {
        remove_timer(task.wait_group, task.timer);
    }

    if abort {
        if request.client.server.verbose & .NORMAL {
            log_error("Aborting sending!");
        }
        request.aborted_response = true;
        request.client.remove_after_request = true;
    }

    on_complete(task);
}

request_yield :: (tasks: .. *Async_Task) #expand {
    assert(context.hyperserve.request.yielded_on.count == 0);
    if tasks.count {
        array_add(*context.hyperserve.request.yielded_on, .. tasks);
    }
    `return;
}


// Print route tree for debugging
debug_print_routes :: (server: *Server) {
    print_node :: (node: *Routing_Node, depth: int) {
        for node.fixed {
            for 0..depth - 1 print("    ");
            print("%\n", it_index);
        }
        for node.literal {
            for 0..depth - 1 print("    ");
            print("/%:\n", it_index);
            print_node(it, depth + 1);
        }
        if node.wildcard.route.path {
            for 0..depth - 1 print("    ");
            print("/{%*}\n", node.wildcard.parameters[node.wildcard.parameters.count - 1]);
        }
        if node.leaf.route.path {
            for 0..depth - 1 print("    ");
            print("/{%}\n", node.leaf.parameters[node.leaf.parameters.count - 1]);
        }
        if node.parameter {
            for 0..depth - 1 print("    ");
            print("/{param_%}:\n", node.parameter_index);
            print_node(node.parameter, depth + 1);
        }
    }

    for node, method: server.routes {
        print("%:\n", method);
        print_node(*node, 1);
    }
}


push_client :: (client: *Client) #expand {
    old_client     := context.hyperserve.client;
    context.hyperserve.client  = client;

    `defer context.hyperserve.client = old_client;
}

push_request :: (request: *Request) #expand {
    old_request     := context.hyperserve.request;
    context.hyperserve.request  = request;

    `defer context.hyperserve.request = old_request;
}

proceed_request_past_authentication :: (request: *Request) {
    assert(request.phase == .AUTH);
    assert(!request.response_status_code);
    request.phase = .HANDLING;
}

#load "routes.jai";
#load "yield.jai";

#scope_file

reset_client_after_request :: (using client: *Client) {
    request_start_time = APOLLO_TIME_INVALID;
    reset(*pending_data);
    array_reset(*header_end_offsets);
    was_cr = false;
    num_pending_newlines = 0;

    reset(request_pool);
}

get_reason_string :: (code: Status_Code) -> string {
    if #complete code == {
        case .AUTO;
        case .OK;                              return "OK";
        case .CREATED;                         return "Created";
        case .ACCEPTED;                        return "Accepted";
        case .NO_CONTENT;                      return "No Content";
        case .PARTIAL_CONTENT;                 return "Partial Content";
        case .MOVED_PERMANENTLY;               return "Moved Permanently";
        case .FOUND;                           return "Found";
        case .SEE_OTHER;                       return "See Other";
        case .NOT_MODIFIED;                    return "Not Modified";
        case .TEMPORARY_REDIRECT;              return "Temporary Redirect";
        case .PERMANENT_REDIRECT;              return "Permanent Redirect";

        case .BAD_REQUEST;                     return "Bad Request";
        case .UNAUTHORIZED;                    return "Unauthorized";
        case .FORBIDDEN;                       return "Forbidden";
        case .NOT_FOUND;                       return "Not Found";
        case .METHOD_NOT_ALLOWED;              return "Method Not Allowed";
        case .CONFLICT;                        return "Conflict";
        case .PAYLOAD_TOO_LARGE;               return "Payload Too Large";
        case .UNSUPPORTED_MEDIA_TYPE;          return "Unsupported Media Type";
        case .UNPROCESSABLE_ENTITY;            return "Unprocessable Entity";
        case .REQUEST_HEADER_FIELDS_TOO_LARGE; return "Request Header Fields Too Large";

        case .INTERNAL_SERVER_ERROR;           return "Internal Server Error";
        case .NOT_IMPLEMENTED;                 return "Not Implemented";
        case .HTTP_VERSION_NOT_SUPPORTED;      return "Http Version Not Supported";
    }

    return "Unknown Status Code";
}

handle_signal_event :: (group: *Wait_Group, signal: s32, server: *Server) {
    if signal == {
        case SIGINT; #through;
        case SIGQUIT; #through;
        case SIGTERM;
            log("Caught signal %. Shutting down…", signal);
            stop(server, graceful = (server.state == .STARTED));
        case;
            log("Caught unexpected signal: %", signal);
            assert(false);
    }
}

handle_connect_event :: (group: *Wait_Group, handle: s32, is_eof: bool, event_type: Wait_Event_Type, server: *Server) {
    assert(handle == server.socket);
    assert(!is_eof);
    assert(event_type == .READ);

    if server.verbose log("Receiving new connection (% open connections)", server.open_connections);
    if is_eof {
        log_error("Server socket was closed unexpectedly.");
        stop(server, graceful = false);
        return;
    }

    #if USE_CLUSTER {
        client_socket, client_addr := cluster_accept(.IPV6, server.socket);
    } else {
        client_socket, client_sock_addr := accept_v6(server.socket);
        client_addr := socket_address(client_sock_addr);
    }
    if client_socket == HANDLE_INVALID {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Couldn’t accept on socket: % %", error_code, error_string);
        return;
    }

    success := set_keepalive(client_socket, true, idle_seconds_before_keepalive = 10, keepalive_interval_seconds = 5, num_keepalive_attempts = 4);
    if !success {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Couldn’t set client socket keepalive: % %", error_code, error_string);
        close(client_socket);
        return;
    }

    success = set_blocking(client_socket, false);
    if !success {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Couldn’t set client socket to non-blocking: % %", error_code, error_string);
        close(client_socket);
        return;
    }
    #if OS == .MACOS {
        set: s32 = 1;
        result := setsockopt(client_socket, SOL_SOCKET, SO_NOSIGPIPE, *set, size_of(type_of(set)));
        if result == -1 {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Could not set socket options: % %", error_value, error_string);
            close(client_socket);
            return;
        }
    }

    server.open_connections += 1;

    add_client(server, client_socket, client_addr);
}

on_request_async_task_complete :: (task: *Async_Task, data: *void) {
    request := cast(*Request) data;
    server := request.client.server;
    array_unordered_remove_by_value(*request.yielded_on, task);

    if !request.yielded_on {
        // Last async task is done! Let’s make progress on this request
        // Re-queue this request for processing on a request thread
        size := server.requests_that_have_yielded.count;
        array_unordered_remove_by_value(*server.requests_that_have_yielded, request);
        assert(server.requests_that_have_yielded.count == size - 1);

        add_work(*server.request_thread_group, request);
    }
}


handle_request_step_done_event :: (group: *Wait_Group, handle: s32, is_eof: bool, event_type: Wait_Event_Type, server: *Server) {
    assert(event_type == .READ);
    assert(handle == server.request_step_done_read_handle);
    assert(!is_eof);

    // @Speed: get_completed_work is very, very wasteful if you have lots of workers and
    // little completed work, which is the case here under low load.
    // We should probably use our own thread pool instead, eventually.
    completed_work := get_completed_work(*server.request_thread_group);
    for work: completed_work {
        // @Speed, @ToDo: Read completed_work.count bytes ouside the loop instead
        data: u8;
        result := repeat_if_interrupted(read(server.request_step_done_read_handle, *data, 1));
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not read from pipe: % %", error_code, error_string);
        } else {
            assert(result == 1);
        }

        request := cast(*Request) work;
        client := request.client;
        assert(!client.waiting_for_data);

        if request.yielded_on {
            array_add(*server.requests_that_have_yielded, request);

            // Request yielded and is not done yet
            context.hyperserve.server = server;
            push_client(client);
            push_request(request);
            push_allocator(pool_allocator_proc, request.pool);

            // @ToDO: We could do this outside the pool...
            tasks_copy := array_copy(request.yielded_on);
            for task: tasks_copy {
                // @ToDo @Speed: We could schedule all the request tasks on a separate work group
                // to avoid overloading the main server’s work group.
                // (We might start dropping new connect requests if the main thread is too busy.)
                begin(task, *server.wait_group, request, on_request_async_task_complete);
            }
        } else {
            // Request is complete
            if client.received_eof || client.remove_after_request {
                if server.verbose log("Removing client % after request % (eof: % / remove after request: %)", client.name, request.id, client.received_eof, client.remove_after_request);
                remove_client(server, client);
            } else {
                if server.verbose log("Re-queueing client % after request %", client.name, request.id);
                // Re-queue the client
                reset_client_after_request(client);
                add_client_to_wait_group(server, client);
            }
        }
    }
}

handle_client_event :: (group: *Wait_Group, handle: s32, is_eof: bool, event_type: Wait_Event_Type, client: *Client) {
    assert(handle == client.socket);
    assert(event_type == .READ);
    server := client.server;
    // push_server(server); Necessary?
    push_client(client);
    handle_client_data(server, client, is_eof);
}

handle_client_timeout :: (group: *Wait_Group, handle: User_Event_Id, client: *Client) {
    server := client.server;
    push_client(client);
    log_error("Timeout while waiting for data from client %. Removing client.", client.name);
    remove_client(server, client);
}

add_client :: (server: *Server, client_socket: s32, client_addr: Socket_Address) {
    client := find_and_occupy_empty_slot(*server.clients);
    client.request_pool = New(Pool); // @Speed: We could keep a pool of pools so that we don’t allocate new memory for every client.
    set_allocators(client.request_pool);

    {
        push_allocator(pool_allocator_proc, client.request_pool);
        remember_allocators(*client.pending_data);
        remember_allocators(*client.header_end_offsets);

        client.server = server;
        client.name = format_address(client_addr);
        client.socket = client_socket;
        client.address = client_addr;
    }

    push_client(client);

    if server.verbose log("Hello %!", client.name);

    add_client_to_wait_group(server, client);
}

add_client_to_wait_group :: (server: *Server, client: *Client) {
    success := add_handles(*server.wait_group, client, handle_client_event, client.socket);
    if !success {
        log_error("Couldn’t add socket of client % to the server wait group.", client.name);
        remove_client(server, client);
        return;
    }

    success, client.receive_timer = add_timer(*server.wait_group, client, handle_client_timeout, RECEIVE_HEADER_TIMEOUT_MS, recurring = false);
    if !success {
        log_error("Couldn’t add receive timeout for client % to the server wait group.", client.name);
        remove_client(server, client);
        return;
    }

    client.waiting_for_data = true;
}

remove_client :: (server: *Server, client: *Client) -> success: bool {
    if server.verbose log("Removing a client (% open connections)", server.open_connections);
    for * server.clients {
        if it.socket == client.socket {
            if client.waiting_for_data {
                remove_handle(*server.wait_group, client.socket);
            }
            if client.receive_timer {
                remove_timer(*server.wait_group, client.receive_timer);
                client.receive_timer = 0;
            }

            deinit(it);
            server.open_connections -= 1;
            remove it;

            return true;
        }
    }

    return false;
}

deinit :: (client: *Client) {
    close_and_reset(*client.socket);
    release(client.request_pool);
    free(client.request_pool);
}

handle_client_data :: (server: *Server, client: *Client, is_eof: bool) {
    should_remove := false;

    if is_eof {
        if server.verbose log("Client % closed the connection.", client.name);
        client.received_eof = true;
        should_remove = true;
    }

    {
        push_allocator(pool_allocator_proc, client.request_pool);
        if client.request_start_time == APOLLO_TIME_INVALID {
            client.request_start_time = current_time_monotonic();
        }

        buffer := ensure_contiguous_space_and_return_available_range(*client.pending_data, 128);
        success, bytes_read := read_handle(client.socket, buffer);
        if !success {
            log_error("Could not read from client %. Closing connection…", client.name);
            remove_client(server, client);
            return;
        }

        if bytes_read {
            new_data := to_string(buffer.data, bytes_read);
            if server.verbose & .TRAFFIC {
                builder: String_Builder;
                append(*builder, new_data);
                append(*builder, "\nHex version:\n");
                for i: 0..new_data.count-1 {
                    print_to_builder(*builder, "% ", formatInt(new_data[i], base = 16, minimum_digits = 2));
                }

                log("Client % said: %", client.name, builder_to_string(*builder,, temp));
            }

            buffer_size := builder_string_length(*client.pending_data);
            if buffer_size == 0 {
                // Check the first byte to early-fail HTTPS requests.
                // (eg. when clients don’t know whether a webcal:// URL is HTTP or HTTPS and try the latter).
                if buffer[0] == 22 { // First byte of TLS handshake
                    log_error("Client % appears to use TLS. Closing connection…", client.name);
                    should_remove = true;
                }
            }

            if !should_remove {
                for i: 0..bytes_read-1 {
                    ch := buffer[i];
                    if ch == #char "\r" {
                        client.was_cr = true;
                    } else if ch == #char "\n" && client.was_cr {
                        client.was_cr = false;
                        client.num_pending_newlines += 1;
                        if client.num_pending_newlines == {
                            case 1;
                                end := buffer_size + i - 1;
                                assert(end >= 0);
                                array_add(*client.header_end_offsets, end);
                            case 2;
                                if server.verbose log("Header complete!");

                                pending_body_data := to_string(buffer.data + i + 1, bytes_read - i - 1);
                                pending_body: String_Builder;
                                append(*pending_body, pending_body_data); // Has to happen before builder_to_string because that will deallocate the buffer that pending_body_data is referencing

                                advance_through_ensured_space(*client.pending_data, i);
                                header_data := builder_to_string(*client.pending_data);
                                should_remove = false;
                                success := hand_off_client_request(server, client, header_data, pending_body);
                                if !success should_remove = true;
                                break;
                        }
                    } else {
                        client.was_cr = false;
                        client.num_pending_newlines = 0;
                    }
                }

                advance_through_ensured_space(*client.pending_data, bytes_read);
                // @ToDo: Check agains max header size we want to allow!
            }
        }
    }

    if should_remove {
        remove_client(server, client);
    }
}

create_request_id :: (client: *Client) -> string {
    defer client.next_request_index += 1;
    return sprint("%_%", client.name, client.next_request_index);
}

hand_off_client_request :: (using server: *Server, client: *Client, header_data: string, pending_body: String_Builder) -> success: bool {
    assert(client.header_end_offsets.count > 0);
    if !header_data {
        log_error("Client %: Empty header.", client.name);
        return false;
    }

    request := New(Request);
    request.client = client;
    request.id = create_request_id(client);
    request.pool = client.request_pool;
    request.header_data = header_data;
    request.pending_body = pending_body;
    request.start_time = client.request_start_time;

    // Further reading is done in the worker thread,
    // so we don't want to wake up the server thread and read whenever the client sends more data
    client.waiting_for_data = false;
    remove_handle(*wait_group, client.socket);

    // @Incomplete: We don’t actually wait for bodies yet because we only handle .GET requests :HandleBody:
    // So we remove the timer here instead of potentially re-setting it until the body is done.
    // But waiting for the body will be triggered from the request thread once it has found a route and
    // knows what should happend with the body. So we should start the body timeout from there.
    // reset_timer(*wait_group, client.receive_timer, RECEIVE_BODY_TIMEOUT_MS, recurring = false);
    remove_timer(*wait_group, client.receive_timer);
    client.receive_timer = 0;

    add_work(*request_thread_group, request);

    return true;
}

thread_handle_request :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
    request := cast(*Request) work;
    client := request.client;
    server := client.server;

    push_allocator(pool_allocator_proc, request.pool);
    context.hyperserve.server = server;
    push_client(client);
    push_request(request);

    if request.phase == .PARSING {
        success := parse_request_and_find_route(server, client, request);
        if !success client.remove_after_request = true;

        if server.state != .STARTED client.remove_after_request = true;

        if !request.response_status_code {
            assert(request.route.handler != null, "parse_request_and_find_route neither replied nor found a request handler");
            assert(!request.yielded_on);
            request.phase = .AUTH;
        }
    }

    if request.phase == .AUTH && !request.response_status_code {
        if request.route.auth_mode == .OFF {
            request.phase = .HANDLING;
        } else {
            auth_methods := server.default_auth_methods; // @ToDo: Allow per-route auth methods
            if !auth_methods {
                log_error("Route requires authentication but no auth methods were specified!");
                respond(status_code = .INTERNAL_SERVER_ERROR);
            } else {
                auth_has_failed := true;
                while request.next_auth_method_index < auth_methods.count {
                    is_last := (request.next_auth_method_index == auth_methods.count - 1);
                    auth_method := auth_methods[request.next_auth_method_index];
                    request.next_auth_method_index += 1;
                    auth_method(request, is_last);
                    if request.yielded_on || request.response_status_code {
                        auth_has_failed = false;
                        break;
                    } else if request.phase == .HANDLING {
                        // Auth method has signalled success, so let’s proceed
                        auth_has_failed = false;
                        break;
                    }
                }
                if auth_has_failed {
                    respond(status_code = .UNAUTHORIZED);
                }
            }
        }
    }

    if request.phase == .HANDLING {
        assert(request.response_status_code == 0);
        request.route.handler(request, request.parsed_parameters);
    }

    if request.phase == .SENDING_RESPONSE {
        // Nothing to do here. Either we‘ve just entered this state and have yielded
        // or we’re done sending and the request is finalized below.
    }

    if !request.yielded_on {
        if request.response_status_code == 0 {
            respond(status_code = .INTERNAL_SERVER_ERROR);
        }
        assert(request.response_status_code != 0);

        end := current_time_monotonic();
        now := current_time_consensus();
        now_string := calendar_to_iso_string(to_calendar(now));
        request_duration_microseconds := to_microseconds(end - request.start_time);

        if server.request_completed_callback server.request_completed_callback(now, request_duration_microseconds, request);

        suffix := ifx request.aborted_response then ", aborted" else "";
        log("%: (%) % % -> % % (%ms%)", now_string, request.id, request.method, request.url, cast(int) request.response_status_code, request.response_status_code, formatFloat(request_duration_microseconds / 1000.0, trailing_width = 2, zero_removal = .NO), suffix);
    }

    data: u8 = 1;
    result := repeat_if_interrupted(write(server.request_step_done_write_handle, *data, 1));
    if result == -1 {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Could not write to pipe: % %", error_code, error_string);
    } else {
        assert(result == 1);
    }

    reset_temporary_storage();

    return .CONTINUE;
}

parse_request_and_find_route :: (server: *Server, client: *Client, request: *Request) -> success: bool {
    offset := client.header_end_offsets[0];
    assert(offset <= request.header_data.count);
    request_line := to_string(request.header_data.data, offset);
    offset += 2; // CRLF

    // Parse request line
    if server.verbose log("Request line: %", request_line);
    found, method_string, remainder := split_from_left(request_line, #char " ");
    if !found {
        log_error("Bad request line: %", request_line);
        respond("Malformed request line", .BAD_REQUEST);
        return false;
    }

    if method_string == {
        case "GET";     request.method = .GET;
        case "POST";    request.method = .POST;
        case "PUT";     request.method = .PUT;
        case "DELETE";  request.method = .DELETE;
        case "PATCH";   request.method = .PATCH;
        case "HEAD";    request.method = .HEAD;
        case "OPTIONS"; request.method = .OPTIONS;
        case;
            log_error("Unsupported request method: %", method_string);
            respond("Unsupported request method", .NOT_IMPLEMENTED);
            return false;
    }

    found, request.url, request.http_version = split_from_left(remainder, #char " ");
    if request.http_version != HTTP_1_0 && request.http_version != HTTP_1_1 {
        log_error("Unsupported HTTP version: %", request.http_version);
        request.http_version = HTTP_1_1;
        respond("", .HTTP_VERSION_NOT_SUPPORTED);
        return false;
    }

    if request.http_version == HTTP_1_0 {
        client.remove_after_request = true;
    } else {
        client.remove_after_request = false;
    }

    if !request.url {
        log_error("Missing request URL");
        respond("Missing request URL", .BAD_REQUEST);
        return false;
    }

    if request.url[0] == #char "/" {
        request.target = request.url;
    } else if begins_with(request.url, "http://") {
        request.target = get_url_target(request.url, "http://");
    } else if begins_with(request.url, "https://") {
        request.target = get_url_target(request.url, "https://");
    }

    if !request.target {
        log_error("Bad request URL: %", request.url);
        respond("Malformed request URL", .BAD_REQUEST);
        return false;
    }

    for i: 1..client.header_end_offsets.count-1 {
        it := client.header_end_offsets[i];
        assert(it > offset);
        assert(it <= request.header_data.count);
        header := to_string(request.header_data.data + offset, it - offset);
        offset = it + 2; // CRLF

        found, name, value := split_from_left(header, #char ":");
        if !found {
            log_error("Bad request header: \"%\"", header);
            respond("Malformed request header", .BAD_REQUEST);
            return false;
        }

        // Normalize
        to_lower_in_place(name);
        value = trim(value);

        table_add(*request.headers, name, value);
        if server.verbose log("Header %: %", name, value);

        if name == {
            case "host";
                request.host = value;
            case "authorization";
                request.authorization = value;
            case "content-length";
                result, success, remainder := to_integer(value);
                if !success || remainder {
                    log_error("Invalid content length: %", value);
                    respond("Invalid content length", .BAD_REQUEST);
                    return false;
                }
                request.content_length = result;
            case "cookie";
                remainder := value;
                while remainder {
                    found, cookie, remainder= := split_from_left(remainder, #char ";");
                    found=, name, value := split_from_left(cookie, #char "=");
                    if !found {
                        respond("Invalid cookie value", .BAD_REQUEST);
                        return false;
                    }
                    name = trim(name);
                    array_add(*request.cookies, .{name, value});
                }

            case "content-type";
                request.content_type = value;
            case "connection";
                to_lower_in_place(value);
                if value == "close" {
                    client.remove_after_request = true;
                } else if value == "keep-alive" {
                    // Note: "Connection: keep-alive" is only specified in HTTP/1.0, but for example Apple Calendar nonetheless sends "Connection: keep-alive" for HTTP/1.1 requests
                    // So we just accept that too, I guess?
                    client.remove_after_request = false;
                } else {
                    log_error("@Incomplete: Handling of connection tokens is not implemented: %", value);
                    respond("Unsupported connection header value", .NOT_IMPLEMENTED);
                    return false;
                }
        }
    }

    if table_find_pointer(*request.headers, "transfer-encoding") && table_find_pointer(*request.headers, "content-length") {
        respond("Only one of transfer-encoding and content-length may be present", .BAD_REQUEST);
        return false;
    }

    if request.http_version == {
        case HTTP_1_0;
            if request.url != request.target {
                // 1.0 only supports target, not urls
                log_error("Bad request URL: %", request.url);
                respond("Malformed request URL", .BAD_REQUEST);
                return false;
            }
            if table_find_pointer(*request.headers, "transfer-encoding") {
                respond(tprint("% does not support transfer-encoding", request.http_version), .BAD_REQUEST);
                return false;
            }
        case HTTP_1_1;
            if !request.host {
                respond("Missing host header", .BAD_REQUEST);
                return false;
            }
        case;
            assert(false);
    }

    if server.verbose & .NORMAL log("Removing after request: %", client.remove_after_request);
    find_route_and_parse_parameters(request);

    return true;
}

get_url_target :: (url: string, prefix: string) -> string {
    if url.count < prefix.count + 1 return "";
    index := find_index_from_left(url, #char "/", prefix.count + 1);
    if index == -1 return "/";
    return slice(url, index, url.count - index);
}

find_route_and_parse_parameters :: (request: *Request) {
    verbose := context.hyperserve.server.verbose;
    node := table_find_pointer(*context.hyperserve.server.routes, request.method);
    if !node {
        log_error("No routes for method %", request.method);
        respond("", .NOT_FOUND);
        return;
    }

    assert(request.method == .GET, "Non-GET requests are not implemented yet!"); // @Incomplete
    // @ToDo: Wait for the remaining body and maybe parse it for non-GET requests :HandleBody:

    found, path, remainder := split_from_left(request.target, #char "?");
    request.path = path;

    query: string;
    fragment: string; // Ignored
    found, query, fragment = split_from_left(remainder, #char "#");
    {
        success, found, entry, path_parameter_values := find_route(node, path);
        if !success {
            log_error("Invalid path: % %", request.method, path);
            respond("Malformed request URL", .BAD_REQUEST);
        }
        if !found {
            log_error("No route for % %", request.method, path);
            respond("", .NOT_FOUND);
            return;
        }

        parameters_info := entry.route.parameters_info;
        params := alloc(parameters_info.runtime_size);
        if parameters_info.initializer {
            parameters_info.initializer(params);
        } else {
            memset(params, 0, parameters_info.runtime_size);
        }

        path_member, path_member_offset := get_field(parameters_info, "path");
        assert(path_member != null);
        path_info := cast(*Type_Info_Struct) path_member.type;
        if path_info.type == .STRUCT {
            path_data := params + path_member_offset;

            assert(path_parameter_values.count == entry.parameters.count);
            for name: entry.parameters {
                value := path_parameter_values[it_index];
                success, error_message := parse_value(path_data, path_info, name, value);
                if !success {
                    respond(tprint("Path parameter \"%\": %", name, error_message), .BAD_REQUEST);
                    return;
                }
            }

            if verbose {
                any: Any;
                any.type = path_info;
                any.value_pointer = path_data;
                if verbose log("Parsed path params: %", any);
            }
        }

        query_member, query_member_offset := get_field(parameters_info, "query");
        assert(query_member != null);
        query_info := cast(*Type_Info_Struct) query_member.type;
        if query_info.type == .STRUCT {
            query_data := params + query_member_offset;
            remainder := query;
            while remainder {
                found: bool;
                part: string;
                found, part, remainder = split_from_left(remainder, #char "&");
                if !part continue; // Allow empty query part. We could also complain…

                equals_found, raw_name, raw_value := split_from_left(part, #char "=");
                if !raw_name {
                    respond("Malformed query", .BAD_REQUEST);
                    return;
                }

                success, name := decode_uri_component(raw_name);
                if !success {
                    respond(tprint("Malformed encoding in query parameter name: %", raw_name), .BAD_REQUEST);
                    return;
                }

                value: string;
                if equals_found {
                    success, value = decode_uri_component(raw_value);
                    if !success {
                        respond(tprint("Malformed encoding in query parameter value of \"%\": %", name, raw_value), .BAD_REQUEST);
                        return;
                    }
                } else {
                    value = "true"; // Interpret name-only parts ("?flag&name=value") as boolean flags
                }

                error_message: string;
                success, error_message = parse_value(query_data, query_info, name, value);
                if !success {
                    respond(tprint("Query parameter \"%\": %", name, error_message), .BAD_REQUEST);
                    return;
                }
            }

            if verbose {
                any: Any;
                any.type = query_info;
                any.value_pointer = query_data;
                if verbose log("Parsed query params: %", any);
            }
        }

        request.route = entry.route;
        request.parsed_parameters = params;
    }
}

// @Cleanup, @Speed: The parameter handling and array stuff is very, very silly atm.
find_route :: (node: *Routing_Node, path: string) -> success: bool, found: bool, entry: Routing_Node.Entry, parameter_strings: [..] string {
    if context.hyperserve.server.verbose log("Trying to find route for \"%\" in %", path, <<node);
    parameter_strings: [..] string;

    if !path {
        log_error("Not at an edge but there’s no more path left");
        return true, false, .{}, parameter_strings;
    }

    assert(path != "");
    fixed := table_find_pointer(*node.fixed, path);
    if fixed {
        array_reserve(*parameter_strings, fixed.parameters.count);
        return true, true, fixed, parameter_strings;
    }

    next_slash_index := find_index_from_left(path, #char "/", 1);
    segment: string;
    remainder: string;
    if next_slash_index == -1 {
        segment = slice(path, 1, path.count - 1);
        remainder = "";
    } else {
        segment = slice(path, 1, next_slash_index - 1);
        remainder = slice(path, next_slash_index, path.count - next_slash_index);
    }
    success, decoded_segment := decode_uri_component(segment);
    if !success return false, false, .{}, parameter_strings;

    literal_node := table_find_pointer(*node.literal, decoded_segment);
    if literal_node {
        success, found, entry, params := find_route(<<literal_node, remainder);
        return success, found, entry, params;
    }

    if !remainder && node.leaf.route.path {
        array_reserve(*parameter_strings, node.leaf.parameters.count);
        array_add(*parameter_strings, decoded_segment);
        return true, true, node.leaf, parameter_strings;
    }

    if node.parameter {
        success, found, entry, params := find_route(node.parameter, remainder);
        if !success return false, false, .{}, parameter_strings;

        array_insert_at(*params, decoded_segment, 0);
        return success, found, entry, params;
    }

    if node.wildcard.route.path {
        array_reserve(*parameter_strings, node.wildcard.parameters.count);
        raw_value := slice(path, 1, path.count - 1);
        // @ToDo: We decode the wildcard part before passing it to the handler.
        // There could be instances where the handler wants the raw value because decoding slashes in the wildcard part
        // changes the meaning of the path!
        success, decoded := decode_uri_component(raw_value);
        if !success return false, false, .{}, parameter_strings;

        array_add(*parameter_strings, decoded);
        return true, true, node.wildcard, parameter_strings;
    }

    log_error("Could not find a matching route for sub-path \"%\"", path);
    return true, false, .{}, parameter_strings;
}

decode_uri_component :: (part: string) -> bool, string {
    index := find_index_from_left(part, #char "%");
    if index == -1  return true, part;

    builder: String_Builder;
    remainder := part;
    while index != -1 {
        if index + 3 > remainder.count return false, "";

        left := slice(remainder, 0, index);
        string_value := slice(remainder, index + 1, 2);
        remainder = slice(remainder, index + 3, remainder.count - index - 3);

        int_value, success, int_remainder := string_to_int(string_value, base = 16, u64);
        if !success || int_remainder return false, "";

        append(*builder, left);
        append(*builder, cast(u8) int_value);
        index = find_index_from_left(remainder, #char "%");
    }
    append(*builder, remainder);

    return true, builder_to_string(*builder);
}

#run {
    success, result := decode_uri_component("%");
    assert(!success, "Result was \"%\"", result);
    success, result = decode_uri_component("%2");
    assert(!success, "Result was \"%\"", result);
    success, result = decode_uri_component("%20");
    assert(success);
    assert(result == " ", "Result was \"%\"", result);
    success, result = decode_uri_component("%20%20");
    assert(success);
    assert(result == "  ", "Result was \"%\"", result);
    success, result = decode_uri_component("%20%0");
    assert(!success, "Result was \"%\"", result);
    success, result = decode_uri_component("pseudo%2fpath");
    assert(success);
    assert(result == "pseudo/path", "Result was \"%\"", result);
}

init_request_thread_group :: (using server: *Server, num_threads: s32) {
    init(*request_thread_group, num_threads, thread_handle_request);

    request_thread_group.name    = "Hyperserve Requests";
    request_thread_group.logging = (server.verbose & .THREADS) != 0;
    request_thread_group.data = server; // Do we need this?
    if server.init_thread_callback {
        for * request_thread_group.worker_info {
            server.init_thread_callback(*it.thread);
        }
    }

    start(*request_thread_group);
}

parse_value :: (data: *void, struct_info: *Type_Info_Struct, member_name: string, to_parse: string) -> success: bool, error_message: string {
    member_info, member_offset := get_field(struct_info, member_name);
    if !member_info {
        return false, "Unknown parameter";
    }

    member_data := data + member_offset;
    success, error_message := parse_value(member_data, member_info.type, to_parse);
    return success, error_message;
}

parse_value :: (dest: *void, info: *Type_Info, to_parse: string) -> success: bool, error_message: string {
    if info.type == {
        // @Incomplete
        case .INTEGER;
            info_int := cast(*Type_Info_Integer) info;
            if info_int.signed {
                int_value, success, remainder := string_to_int(to_parse, T = s64);
                if !success || remainder return false, "Value is not a valid signed integer.";

                valid, low, high := Reflection.range_check_and_store(int_value, info_int, dest);
                if !valid return false, tprint("Value must be between % and %", low, high);
            } else {
                int_value, success, remainder := string_to_int(to_parse, T = u64);
                if !success || remainder return false, "Value is not a valid unsigned integer.";

                valid, low, high := Reflection.range_check_and_store(int_value, info_int, dest);
                if !valid return false, tprint("Value must be between % and %", low, high);
            }
            return true, "";
        // case .FLOAT;
        case .BOOL;
            lower_value := to_lower_copy(to_parse,, temp);
            bool_pointer := cast(*bool) dest;
            if lower_value == {
                case "true"; #through;
                case "yes"; #through;
                case "1";
                    <<bool_pointer = true;

                case "false"; #through;
                case "no"; #through;
                case "0";
                    <<bool_pointer = false;

                case;
                    return false, "Unsupported boolean value. Supported values are: \"true\", \"yes\", \"1\", \"false\", \"no\", and \"0\"";
            }
            return true, "";

        case .STRING;
            string_pointer := cast(*string) dest;
            <<string_pointer = to_parse;
            return true, "";
        case .ENUM;
            info_enum := cast(*Type_Info_Enum) info;
            // @ToDo: Allow other normalization
            normalized_value := to_upper_copy(to_parse,, temp);
            for name: info_enum.names {
                if name == normalized_value {
                    int_value := info_enum.values[it_index];
                    valid := Reflection.range_check_and_store(int_value, info_enum.internal_type, dest);
                    assert(valid);
                    return true, "";
                }
            }

            builder: String_Builder;
            append(*builder, "Invalid value. Allowed: ");
            for name: info_enum.names {
                normalized_name := to_lower_copy(name,, temp);
                if it_index append(*builder, ", ");
                append(*builder, normalized_name);
            }

            return false, builder_to_string(*builder);
        case .ARRAY;
            info_array := cast(*Type_Info_Array) info;
            element_size := info_array.element_type.runtime_size;
            element_data: *void;
            array_count_pointer: *s64;
            if info_array.array_type == {
                case .RESIZABLE;
                    array := cast(*Resizable_Array) dest;
                    array_count_pointer = *array.count;
                    maybe_grow(array, element_size);
                    element_data = array.data + array.count * element_size;
                case .VIEW;
                    // @Speed: This is stupidly inefficient.
                    // But without keeping a side-list of dynamic arrays we allocated, we can’t do better
                    // because we can’t know if it’s a default value or somethign we allocated for a previous value.
                    array := cast(*Array_View_64) dest;
                    array_count_pointer = *array.count;
                    old := <<array;
                    array.data = alloc((old.count + 1) * element_size);
                    if old.data {
                        memcpy(array.data, old.data, old.count * element_size);
                    }
                    element_data = array.data + array.count * element_size;

                case; assert(false, "@Incomplete: arguments of array type % are not yet implemented", info_array.array_type);
            }
            success, error_message := parse_value(element_data, info_array.element_type, to_parse);
            if !success	return false, error_message;
            <<array_count_pointer += 1;

            return true, "";

        // case .POINTER;
        // case .PROCEDURE;
        // case .VOID;
        // case .STRUCT;
        // case .OVERLOAD_SET;
        // case .ANY;
        // case .POLYMORPHIC_VARIABLE;
        // case .TYPE;
        // case .CODE;
        // case .VARIANT;
        case;
            log_error("@Incomplete: Parsing parameters of type % is not yet supported", info.type);
            return false, "Internal parser error";
    }
}


#scope_module

read_handle :: (handle: s32, buffer: [] u8) -> success: bool, bytes_read: int {
    flags: MSG;
    #if OS == .LINUX {
        flags |= .NOSIGNAL;
    }
    bytes_read := recv(handle, buffer.data, cast(u64) buffer.count, flags);
    if bytes_read < 0 {
        read_error := errno();
        if read_error == EAGAIN || read_error == EWOULDBLOCK {
            return true, 0;
        }

        return false, 0;
    }

    return true, bytes_read;
}


repeat_if_interrupted :: (call: Code) -> s64 #expand {
    while true {
        result := #insert call;
        if result == -1 {
            error_code := System.get_error_value();
            if error_code == EINTR || error_code == EAGAIN {
                // Got interrupted, try again.
                continue;
            }
        }
        return result;
    }
}

#import "Basic";
#import "Bucket_Array";
#import "Hash_Table";
#import "Pool";
#import "Thread";
#import "Socket";
#import "String";
System     :: #import "System";
Reflection :: #import "Reflection";

#if OS != .WINDOWS {
    #import "POSIX";
}

#import "wait_group"; // https://github.com/rluba/wait_group

#if USE_CLUSTER {
    #import "cluster"; // https://github.com/rluba/cluster
}

// Copied from Reflection, which doesn’t contain it anymore.
maybe_grow :: (array: *Resizable_Array, element_size: s64) {
	if array.count >= array.allocated {
		reserve := 2 * array.allocated;
		if reserve < 8  reserve = 8;

		if !array.allocator.proc {
			if context.allocator.proc {
				array.allocator      = context.allocator;
			} else {
				array.allocator      = context.default_allocator;
			}
		}

		array.data = realloc(array.data, reserve * element_size, array.allocated * element_size,, array.allocator);
		assert(array.data != null); // Program will die if we couldn't get memory. We can think about an alternative strategy, but it's hard to know what would be reasonable.

		array.allocated = reserve;
	}
}


