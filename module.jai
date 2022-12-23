// @ToDo:
// - Decode bodies (JSON, multipart, …)
// - Declare the accepted content types for body parsing as route options
// - Offer option to stream the body instead of decoding it?
// - Add option to limit body size
// - Offer more response options (custom headers, …)
// - Support for transfer-encoding: chunked
// - handle Http_Method.OPTIONS correctlty
// …


HANDLE_INVALID :: -1;

Server :: struct {
    verbose         := false;
    socket:         s32 = HANDLE_INVALID;
    sigint_handle:  s32 = HANDLE_INVALID;
    sigquit_handle: s32 = HANDLE_INVALID;
    sigterm_handle: s32 = HANDLE_INVALID;
    wait_group:     Wait_Group;

    should_quit:    bool;
    clients:        Bucket_Array(Client, 64);

    routes:         Table(Http_Method, Routing_Node);
    request_thread_group: Thread_Group;
    request_done_read_handle:  s32 = HANDLE_INVALID;
    request_done_write_handle: s32 = HANDLE_INVALID;
}

Client :: struct {
    server: *Server;
    name: string;
    socket: s32 = HANDLE_INVALID;
    address: sockaddr_in;

    next_request_index: int;

    received_eof: bool;
    remove_after_request: bool;

    // Request data
    request_pool: *Pool;
    pending_data: String_Builder;
    header_end_offsets: [..] int;
    was_cr: bool;
    num_pending_newlines: int;
}

Request :: struct {
    client: *Client;
    pool: *Pool;
    id: string;
    header_data: string;

    method: Http_Method;
    url: string;
    http_version: string;

    target: string;

    headers: Table(string, string); // @ToDo: Add abstraction for on-the-fly decoding of encoded values?
    host: string;
    content_length: int;
    content_type: string;
    // @ToDo: More fields for commonly referenced headers

    pending_body: String_Builder;

    start_time: Apollo_Time = APOLLO_TIME_INVALID;
    response_status_code: Status_Code;
}

HTTP_1_0 :: "HTTP/1.0";
HTTP_1_1 :: "HTTP/1.1";

Hyperserve_Context :: struct {
    server: *Server;
    client: *Client;
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

shutdown :: (using server: *Server, timeout_milliseconds: s32 = 60 * 1000) {
    if request_thread_group.initted && !request_thread_group.should_exit {
        shutdown(*request_thread_group, timeout_milliseconds);
    }
}

deinit :: (using server: *Server) {
    shutdown(server, 0);

    for * clients {
        remove_client(server, it);
    }

    deinit(*wait_group);

    close_and_reset(*socket);
    close_and_reset(*sigint_handle);
    close_and_reset(*sigquit_handle);
    close_and_reset(*sigterm_handle);
    close_and_reset(*request_done_read_handle);
    close_and_reset(*request_done_write_handle);
}

listen :: (server: *Server, port: u16, num_threads: s32 = 10) -> bool {
    // @ToDo: IPv6
    // @ToDo: optionally restrict interface
    server.socket = socket(AF_INET, .STREAM, 0);
    if server.socket == HANDLE_INVALID {
        error_code := get_last_socket_error();
        error_string := System.get_error_string(error_code);
        log_error("Couldn’t create socket: % %", error_code, error_string);
        return false;
    }

    success := set_blocking(server.socket, false);
    if !success {
        error_code := get_last_socket_error();
        error_string := System.get_error_string(error_code);
        log_error("Couldn’t set socket to non-blocking: % %", error_code, error_string);
        deinit(server);
        return false;
    }

    reuse_addr: s32 = 1;
    result := setsockopt(server.socket, SOL_SOCKET, SO_REUSEADDR, *reuse_addr, size_of(type_of(reuse_addr)));
    if result == -1 {
        error_code := get_last_socket_error();
        error_string := System.get_error_string(error_code);
        log_error("Couldn’t set socket options: % %", error_code, error_string);
        deinit(server);
        return false;
    }

    result = bind(server.socket, INADDR_ANY, port);
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

    success = init(*server.wait_group);
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

    server.request_done_read_handle  = worker_pipes[0];
    server.request_done_write_handle = worker_pipes[1];

    success = add_handles(*server.wait_group, server.socket, server.request_done_read_handle);
    if !success {
        deinit(server);
        return false;
    }

    // @ToDo: Strangely, our signal handlers are not called for SIGQUIT or SIGTERM on macOS.
    // Needs investigation…
    success = add_signals(*server.wait_group, SIGINT, SIGQUIT, SIGTERM); 
    if !success {
        deinit(server);
        return false;
    }


    init_request_thread_group(server, num_threads);

    return true;
}

Status_Code :: enum u16 {
    // @Incomplete
    OK                              :: 200;
    CREATED                         :: 201;
    ACCEPTED                        :: 202;
    NO_CONTENT                      :: 204;
    MOVED_PERMANENTLY               :: 301;
    FOUND                           :: 302;
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

update :: (using server: *Server) -> bool{
    success := wait_for_events(*wait_group, server, handle_event);
    if !success {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Couldn’t wait for events. Exiting…");
        should_quit = true;
    }

    return should_quit;
}

respond :: (response: string, status_code := Status_Code.OK, content_type := "text/plain") {
    using context.hyperserve;

    if request.response_status_code {
        log_error("Trying to send a response to request %, but a % response was already sent!", request.id, request.response_status_code);
        return;
    }

    request.response_status_code = status_code;

    builder: String_Builder;
    defer free_buffers(*builder);
    // @ToDo: Maybe keep track of the HTTP version that was send and use the same version in the response?
    print_to_builder(*builder, "% % %\r\n", request.http_version, cast(int) status_code, get_reason_string(status_code));
    print_to_builder(*builder, "content-length: %\r\n", response.count);
    print_to_builder(*builder, "content-type: %; charset=utf-8\r\n", content_type);
    // @Incomplete: custom headers
    append(*builder, "\r\n");
    append(*builder, response);

    if server.verbose log("Responding with:\n%", builder_to_string(*builder, do_reset = false)); 

    // Actually send the response
    // @ToDo: Do this in a blocking way instead of busy-looping!
    buffer := get_base_buffer(*builder);
    while buffer {
        data := get_buffer_data(buffer);
        remaining := buffer.count;
        while remaining {
            result := send(client.socket, data, cast(u64) remaining, 0);
            if result == -1 {
                error_code := get_last_socket_error();
                error_string := System.get_error_string(error_code);
                log_error("Could not send response: % %", error_code, error_string);
                return;
            }
            assert(result <= remaining);
            data += result;
            remaining -= result;
        }

        buffer = buffer.next;
    }
}

// Print route tree for debugging
debug_print_routes :: (server: *Server) {
    for node, method: server.routes {
        print("%:\n", method);
        print_node(*node, 1);
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
            if node.edge.route.path {
                for 0..depth - 1 print("    ");
                print("/{%}\n", node.edge.parameters[node.edge.parameters.count - 1]);
            }
            if node.parameter {
                for 0..depth - 1 print("    ");
                print("/{param_%}:\n", node.parameter_index);
                print_node(node.parameter, depth + 1);
            }
        }
    }
}


#load "wait.jai";
#load "routes.jai";

#scope_file


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

reset_client_after_request :: (using client: *Client) {
    reset(*pending_data);
    array_reset(*header_end_offsets);
    was_cr = false;
    num_pending_newlines = 0;

    reset(request_pool);
}

get_reason_string :: (code: Status_Code) -> string {
    if #complete code == {
        case .OK;                              return "OK";
        case .CREATED;                         return "Created";
        case .ACCEPTED;                        return "Accepted";
        case .NO_CONTENT;                      return "No Content";
        case .MOVED_PERMANENTLY;               return "Moved Permanently";
        case .FOUND;                           return "Found";
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

handle_event :: (is_signal: bool, handle: s32, is_eof: bool, server: *Server) {
    if is_signal {
        if handle == {
            case SIGINT; 
                log("Caught SIGINT. Quitting for now…");
                server.should_quit = true;
            case SIGQUIT; 
                log("Caught SIGQUIT. Quitting…");
                server.should_quit = true;
            case SIGTERM; 
                log("Caught SIGTERM. Quitting…");
                server.should_quit = true;
            case;
                log("Caught unexpected signal: %", handle);
                assert(false);
        }
    } else if handle == server.socket {
        if server.verbose log("Receiving new connection");
        if is_eof {
            log_error("Server socket was closed unexpectedly.");
            server.should_quit = true;
            return;
        }

        client_socket, client_addr := accept(server.socket);
        if client_socket == HANDLE_INVALID {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Couldn’t accept on socket: % %", error_code, error_string);
            return;
        }

        add_client(server, client_socket, client_addr);
    } else if handle == server.request_done_read_handle {
        // @Speed: get_completed_work is very, very wasteful if you have lots of workers and
        // little completed work, which is the case here under low load.
        // We should probably use our own thread pool instead, eventually.
        completed_work := get_completed_work(*server.request_thread_group);
        for work: completed_work {
            if server.verbose log("Got completed work");

            data: u8;
            result := repeat_if_interrupted(read(server.request_done_read_handle, *data, 1));
            if result == -1 {
                error_code, error_string := System.get_error_value_and_string();
                log_error("Could not read from pipe: % %", error_code, error_string);
            } else {
                assert(result == 1);
            }

            request := cast(*Request) work;
            client := request.client;
            if client.received_eof || client.remove_after_request {
                remove_client(server, client);
            } else {
                // Re-queue the client
                reset_client_after_request(client);
                add_handles(*server.wait_group, client.socket);
            }
        }
    } else {
        // Clients…
        client: *Client;
        for * server.clients {
            if it.socket == handle {
                client = it;
                break;
            }
        }
        if !client {
            log_error("Could not find client for handle %", handle);
            return;
        }

        push_client(client);
        handle_client_data(server, client, is_eof);
    }
}

add_client :: (server: *Server, client_socket: s32, client_addr: sockaddr_in) -> success: bool {
    // ToDo: Create an allocator for this client (and also use it for the name)
    client := find_and_occupy_empty_slot(*server.clients);
    client.server = server;
    client.name = to_string(client_addr);
    client.socket = client_socket;
    client.address = client_addr;
    client.request_pool = New(Pool);
    set_allocators(client.request_pool);

    {
        push_allocator(pool_allocator_proc, client.request_pool);
        remember_allocators(*client.pending_data);
        remember_allocators(*client.header_end_offsets);
    }

    push_client(client);

    if server.verbose log("Hello %!", client.name);
    success := add_handles(*server.wait_group, client_socket);
    if !success {
        log_error("Couldn’t add socket of client % to the server wait group.", client.name);
        deinit(client);
        return false;
    }

    return true;
}

remove_client :: (server: *Server, client: *Client) -> success: bool {
    for * server.clients {
        if it.socket == client.socket {
            deinit(it);
            remove it;
            return true;
        }
    }

    return false;
}

deinit :: (client: *Client) {
    free(client.name);
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

        buffer := ensure_contiguous_space_and_return_available_range(*client.pending_data, 128);
        success, bytes_read := read_handle(client.socket, buffer);
        if !success {
            log_error("Could not read from client %. Closing connection…", client.name);
            remove_client(server, client);
            return;
        }

        if bytes_read {
            new_data := to_string(buffer.data, bytes_read);
            if server.verbose log("Client % said: %", client.name, new_data);

            buffer_size := builder_string_length(*client.pending_data);
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
    request.start_time = current_time_monotonic();

    // Further reading is done in the worker thread,
    // so we don't want to wake up the server thread and read whenever the client sends more data
    remove_handle(*wait_group, client.socket);

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

    success := parse_and_handle_request(server, client, request);
    if !success client.remove_after_request = true;

    end := current_time_monotonic();
    now := current_time_consensus();
    now_string := calendar_to_iso_string(to_calendar(now));
    log("%: % % -> % (%ms)", now_string, request.method, request.url, request.response_status_code, formatFloat(to_microseconds(end - request.start_time) / 1000.0, trailing_width = 2, zero_removal = .NO));

    data: u8 = 1;
    result := repeat_if_interrupted(write(server.request_done_write_handle, *data, 1));
    if result == -1 {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Could not write to pipe: % %", error_code, error_string);
    } else {
        assert(result == 1);
    }

    reset_temporary_storage();

    return .CONTINUE;
}

parse_and_handle_request :: (server: *Server, client: *Client, request: *Request) -> success: bool {
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
            case "content-length";
                result, success, remainder := to_integer(value);
                if !success || remainder {
                    log_error("Invalid content length: %", value);
                    return false;
                }
                request.content_length = result;

            case "content-type";
                request.content_type = value;
            case "connection";
                to_lower_in_place(value);
                if value == "close" {
                    client.remove_after_request = true;
                } else if request.http_version == HTTP_1_0 && value == "keep-alive" { 
                    client.remove_after_request = false;
                } else {
                    log_error("@Incomplete: Handling of connection tokens is not implemented");
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

    handle_request(request);
    if !request.response_status_code {
        log_error("Request handler for request % did not send a response.", request.id);
        return false;
    }

    return true;
}

get_url_target :: (url: string, prefix: string) -> string {
    if url.count < prefix.count + 1 return "";
    index := find_index_from_left(url, #char "/", prefix.count + 1);
    if index == -1 return "/";
    return slice(url, index, url.count - index);
}

handle_request :: (request: *Request) {
    verbose := context.hyperserve.server.verbose;
    node := table_find_pointer(*context.hyperserve.server.routes, request.method);
    if !node {
        log_error("No routes for method %", request.method);
        respond("", .NOT_FOUND);
        return;
    }

    found, path, remainder := split_from_left(request.target, #char "?");
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
                if !raw_name || !equals_found {
                    respond("Malformed query", .BAD_REQUEST);
                    return;
                }

                success, name := decode_uri_component(raw_name);
                value: string;
                success, value = decode_uri_component(raw_value);

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

        entry.route.handler(request, params);
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

    if !remainder && node.edge.route.path {
        array_reserve(*parameter_strings, node.edge.parameters.count);
        array_add(*parameter_strings, decoded_segment);
        return true, true, node.edge, parameter_strings;
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
    request_thread_group.logging = server.verbose;
    request_thread_group.data = server; // Do we need this?

    start(*request_thread_group);
}

parse_value :: (data: *void, struct_info: *Type_Info_Struct, member_name: string, to_parse: string) -> success: bool, error_message: string {
    success := true;

    info_member, member_offset := get_field(struct_info, member_name);
    if !info_member {
        return false, "Unknown parameter";
    }

    member_data := data + member_offset;

    if info_member.type.type == {
        // @Incomplete
        case .INTEGER;
            int_info := cast(*Type_Info_Integer) info_member.type;
            if int_info.signed {
                int_value, success, remainder := string_to_int(to_parse, T = s64);
                if !success || remainder return false, "Value is not a valid signed integer.";

                valid, low, high := Reflection.range_check_and_store(int_value, int_info, member_data);
                if !valid return false, tprint("Value must be between % and %", low, high);
            } else {
                int_value, success, remainder := string_to_int(to_parse, T = u64);
                if !success || remainder return false, "Value is not a valid unsigned integer.";

                valid, low, high := Reflection.range_check_and_store(int_value, int_info, member_data);
                if !valid return false, tprint("Value must be between % and %", low, high);
            }
            return true, "";
        // case .FLOAT;
        // case .BOOL;
        case .STRING;
            dest := cast(*string) member_data;
            <<dest = to_parse;
            return true, "";
        // case .ENUM;
        // case .POINTER;
        // case .PROCEDURE;
        // case .VOID;
        // case .STRUCT;
        // case .ARRAY;
        // case .OVERLOAD_SET;
        // case .ANY;
        // case .POLYMORPHIC_VARIABLE;
        // case .TYPE;
        // case .CODE;
        // case .VARIANT;
        case;
            log_error("@Incomplete: Parsing parameters of type % is not yet supported", info_member.type.type);
            return false, "Internal parser error";
    }
}

#scope_module

read_handle :: (handle: s32, buffer: [] u8) -> success: bool, bytes_read: int {
    bytes_read := read(handle, buffer.data, cast(u64) buffer.count);
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
