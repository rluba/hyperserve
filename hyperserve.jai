Args :: struct {
	port: u16 = 80;
}

Server :: struct {
	socket: s32 = HANDLE_INVALID;
	sigint_handle: s32 = HANDLE_INVALID;
	sigquit_handle: s32 = HANDLE_INVALID;
	sigterm_handle: s32 = HANDLE_INVALID;
	wait_group: Wait_Group;

	should_quit: bool;
	clients: Bucket_Array(Client, 64);
}

Client :: struct {
	name: string;
	socket: s32 = HANDLE_INVALID;
	address: sockaddr_in;

	next_request_index: int;

	// Request data
	request_pool: *Pool;
	pending_data: String_Builder;
	header_end_offsets: [..] int;
	was_cr: bool;
	num_pending_newlines: int;
}

Request :: struct {
	pool: *Pool;
	id: string;
	header_data: string;
	method: Http_Method;
	url: string;

	headers: Table(string, string); // @ToDo: Add abstraction for on-the-fly decoding of encoded values?
	content_length: int;
	content_type: string;
	// @ToDo: More fields for commonly referenced headers

	pending_body: String_Builder;
}

Hyperserve_Context :: struct {
	server: Server;
	client: *Client;
	request: *Request;
}

#add_context hyperserve: Hyperserve_Context;

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


Http_Method :: enum {
	GET;
	POST;
	PUT;
	DELETE;
	PATCH;
	HEAD;
	OPTIONS;
}

main :: () {
	success, args := parse_arguments(Args);
	if !success {
		// @ToDo!
		log("Invalid arguments");
		exit(1);
	}

	using context.hyperserve;

	// @ToDo: IPv6
	server.socket = socket(AF_INET, SOCK_STREAM, 0);
	if server.socket == HANDLE_INVALID {
		error_code, error_string := System.get_error_value_and_string();
		log_error("Couldn’t create socket: % %", error_code, error_string);
		exit(1);
	}

    result := fcntl(server.socket, F_SETFL, fcntl(server.socket, F_GETFL) | O_NONBLOCK);
    if result == -1 {
		error_code, error_string := System.get_error_value_and_string();
		log_error("Couldn’t set socket to non-blocking: % %", error_code, error_string);
		exit(1);
    }

    reuse_addr: s32 = 1;
    result = setsockopt(server.socket, SOL_SOCKET, SO_REUSEADDR, *reuse_addr, size_of(type_of(reuse_addr)));
	if result == -1 {
		error_code, error_string := System.get_error_value_and_string();
		log_error("Couldn’t set socket options: % %", error_code, error_string);
		exit(1);
	}

	result = bind(server.socket, INADDR_ANY, args.port);
	if result == -1 {
		error_code, error_string := System.get_error_value_and_string();
		log_error("Couldn’t bind socket: % %", error_code, error_string);
		exit(1);
	}

	result = listen(server.socket, SOMAXCONN);
	if result == -1 {
		error_code, error_string := System.get_error_value_and_string();
		log_error("Couldn’t listen on socket: % %", error_code, error_string);
		exit(1);
	}
	log("listening on socket %\n", server.socket);

	// @ToDo: Use kevent for SIGNAL on macoOS
	// server.sigint_handle = create_signal_handler(SIGINT);
	// server.sigquit_handle = create_signal_handler(SIGQUIT);
	// server.sigterm_handle = create_signal_handler(SIGTERM);

	success = init(*server.wait_group);
	if !success {
		deinit(*server);
		exit(1);
	}

	success = add_handles(*server.wait_group, server.socket);
	if !success {
		deinit(*server);
		exit(1);
	}

	if success {
		// @ToDo
		// , server.sigint_handle, server.sigquit_handle, server.sigterm_handle);
		while !server.should_quit {
			success := wait_for_events(*server.wait_group, *server, handle_event);
			if !success {
				error_code, error_string := System.get_error_value_and_string();
				log_error("Couldn’t wait for events. Exiting…");
				server.should_quit = true;
			}
		}
	}
	deinit(*server);

}

deinit :: (using server: *Server) {
	// @ToDo: Give clients a chance to finish
	for * clients {
		remove_client(server, it);
	}

	close_and_reset(*socket);
	close_and_reset(*sigint_handle);
	close_and_reset(*sigquit_handle);
	close_and_reset(*sigterm_handle);
}

handle_event :: (handle: s32, is_eof: bool, server: *Server) {
	assert(server == *context.hyperserve.server);
	if handle == server.sigint_handle {
		log("Caught SIGINT. Quitting for now…");
		server.should_quit = true;
	} else if handle == server.sigquit_handle {
		log("Caught SIGQUIT. Quitting…");
		server.should_quit = true;
	} else if handle == server.sigterm_handle {
		log("Caught SIGTERM. Quitting…");
		server.should_quit = true;
	} else if handle == server.socket {
		log("Receiving new connection");
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
	} else {
		// Clients…
		client: *Client;
		for * server.clients {
			if it.socket == handle {
				client = it;
				break;
			}
		}

		if client.socket == HANDLE_INVALID {
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

	log("Hello %!", client.name);
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
	{
		push_allocator(pool_allocator_proc, client.request_pool);

		buffer := ensure_contiguous_space_and_return_available_buffer(*client.pending_data, 128);
		success, bytes_read := read_handle(client.socket, buffer);
		if !success {
			log_error("Could not read from client %. Closing connection…", client.name);
			remove_client(server, client);
			return;
		}

		if bytes_read {
			new_data := to_string(buffer.data, bytes_read);
			log("Client % said: %", client.name, new_data);

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
							log("Header complete!");

							pending_body_data := to_string(buffer.data + i + 1, bytes_read - i - 1);
							pending_body: String_Builder;
							append(*pending_body, pending_body_data); // Has to happen before builder_to_string because that will deallocate the buffer that pending_body_data is referencing

							advance_through_ensured_space(*client.pending_data, i);
							header_data := builder_to_string(*client.pending_data);
							success := parse_and_handle_request(server, client, header_data, pending_body, client.request_pool);
							if !success {
								should_remove = true;
							}
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

	if is_eof {
		log("Client % closed the connection.", client.name);
		should_remove = true;
	}
	
	if should_remove {
		remove_client(server, client);
	}
}

create_request_id :: (client: *Client) -> string {
	defer client.next_request_index += 1;
	return sprint("%_%", client.name, client.next_request_index);
}

parse_and_handle_request :: (server: *Server, client: *Client, header_data: string, pending_body: String_Builder, pool: *Pool) -> success: bool {
	assert(client.header_end_offsets.count > 0);
	if !header_data {
		log_error("Client %: Empty header.", client.name);
		return false;
	}

	request := New(Request);
	request.id = create_request_id(client);
	request.pool = pool;
	request.header_data = header_data;
	request.pending_body = pending_body;
	push_request(request);

	offset := client.header_end_offsets[0];
	assert(offset <= request.header_data.count);
	request_line := to_string(request.header_data.data, offset);
	offset += 2; // CRLF

	// Parse request line
	log("Request line: %", request_line);
	found, method_string, remainder := split_from_left(request_line, #char " ");
	if !found {
		log_error("Bad request line: %", request_line);
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
			return false;
	}

	http_version: string;
	found, request.url, http_version = split_from_left(remainder, #char " ");
	if http_version != "HTTP/1.1" {
		log_error("Unsupported HTTP version: %", http_version);
		return false;
	}

	if !request.url {
		log_error("Bad request URL: %", request.url);
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
			log_error("Bad request header: %", header);
			return false;
		}

		// Normalize
		to_lower_in_place(name);
		value = trim(value);

		table_add(*request.headers, name, value);
		log("Header %: %", name, value);
		
		if name == {
			case "content-length";
				result, success, remainder := to_integer(value);
				if !success || remainder {
					log_error("Invalid content length: %", value);
					return false;
				}
				request.content_length = result;

			case "content-type";
				request.content_type = value;
		}
	}

	// @ToDo: Handle request

	remove_client(server, client);

	return true;
}

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

// client_thread_group: Thread_Group;

// init_client_thread_group :: () {
//     // We want to make about as many threads as we have CPUs. More than that
//     // will overwhelm our computer with context-switching waste work!
//     num_cpus := get_number_of_processors();

//     assert(num_cpus >= 1);

//     #if (OS == .WINDOWS) || (OS == .LINUX) {
//         // This routine reports hyperthreads, so, divide by two, because of Intel marketing.
//         num_cpus /= 2;
//     }

//     if num_cpus > 200  num_cpus = 200;  // Clamp to a value that is reasonable as of 2021, in case we get weird data.

//     // In a typical program, you want the "main thread" to be able to use a CPU, so,
//     // only allocate as many threads as we have other CPUs.
//     // Launch at least 2 threads, because for this example, we want to show multiple threads
//     // running at the same time.
//     num_threads := max(num_cpus - 1, 2);

//     logprint("Thread Group Example", "This machine reports % CPUs; starting % threads.\n", num_cpus, num_threads);

//     init(*client_thread_group, num_threads, thread_handle_client);

//     // After initializing a Thread_Group, there are various data members you can set
//     // to control behavior. See the definition of Thread_Group in modules/Thread.
//     thread_group.name    = "Clients";
//     thread_group.logging = true;

//     {
//         // You are free to set the Thread.user_data member on any of the threads created by the group.
//         // But ... you have to do that before calling start(). Here we will just set a dummy user_data,
//         // to show it's working.

//         Dummy_Data :: struct {
//             name := "Lord Dimwit Flathead the Excessive";
//         }

//         dummy_data := New(Dummy_Data);

//         for * thread_group.worker_info {
//             it.thread.data = *dummy_data;
//         }
//     }
// }

#import "Basic";
#import "POSIX";
#import "Thread";
System :: #import "System";


#load "wait.jai";
#load "socket.jai";

#scope_file

#import "Command_Line";
#import "Hash_Table";
#import "Pool";
#import "String";
#import "Bucket_Array";
