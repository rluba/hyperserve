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
	clients: [..] Client;
}

Client :: struct {
	name: string;
	socket: s32 = HANDLE_INVALID;
	address: sockaddr_in;
}

main :: () {
	success, args := parse_arguments(Args);
	if !success {
		// @ToDo!
		log("Invalid arguments");
		exit(1);
	}

	server: Server;

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

		buffer: [1024] u8;
		success, bytes_read := read_handle(handle, buffer);
		if !success {
			log_error("Could not read from client %. Closing connection…", client.name);
			remove_client(server, client);
			return;
		}

		if bytes_read {
			read: string;
			read.data = buffer.data;
			read.count = bytes_read;
			log("Client % said: %", client.name, read);
		}

		if is_eof {
			log("Client % closed the connection.", client.name);
			remove_client(server, client);
		}
	}
}

add_client :: (server: *Server, client_socket: s32, client_addr: sockaddr_in) -> success: bool {
	// ToDo: Allocator for this client (and also use it for the name)
	client: Client;
	client.name = to_string(client_addr);
	client.socket = client_socket;
	client.address = client_addr;
	log("Hello %!", client.name);
	success := add_handles(*server.wait_group, client_socket);
	if !success {
		log_error("Couldn’t add socket of client %.", client.name);
		deinit(*client);
		return false;
	}

	array_add(*server.clients, client);
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
