Args :: struct {
    port: u16 = 80;
    verbose: bool;
    threads: s32 = 10;
}

main :: () {
    #if OS == .WINDOWS {
        socket_init();
    }

    success, args := parse_arguments(Args);
    if !success {
        // @ToDo!
        log("Invalid arguments");
        exit(1);
    }

    server: Server;
    server.verbose = args.verbose;

    {
        success := add_route(*server, .GET, "/", (request: *Request, parameters: *Request_Parameters()) {
            log("Got root request!");
            respond("pretend this is index.html", content_type = "text/html");
        });
        success &= add_route(*server, .GET, "/ping", (request: *Request, parameters: *Request_Parameters()) {
            respond("pong", content_type = "text/plain");
        });
        success &= add_route(*server, .POST, "/", (request: *Request, parameters: *Request_Parameters()) {
            log("Got root POST!");
            respond("Something was wrong with your post", 422);
        });

        success &= add_route(*server, .GET, "/long/path/but/no/params", (request: *Request, parameters: *Request_Parameters()) {
            log("Got long path request!");
            respond("");
        });
        success &= add_route(*server, .GET, "/{prefix}/long/path/but/no/more/params", (request: *Request, parameters: *Request_Parameters(struct {prefix: string;})) {
            log("Got long path request with prefix: %!", request.url);
            respond("");
        });
        success &= add_route(*server, .GET, "/{path}", (request: *Request, parameters: *Request_Parameters(struct {path: string;})) {
            log("Got path request: %", request.url);
            respond("");
        });
        success &= add_route(*server, .GET, "/ping/{path*}", (request: *Request, parameters: *Request_Parameters(struct {path: string;})) {
            log("Got ping request with path: %", request.url);
            respond("");
        });

        {
            Path_Params :: struct {
                id: u64;
                upload_id: int;
                path: string;
                not_used := "Bad";
            }
            Query_Params :: struct {
                arg1: string;
                arg2: string;
                arg3 := 1;
            }
            success &= add_route(*server, .GET, "/members/{id}/upload/{upload_id}/{path*}", (request: *Request, parameters: *Request_Parameters(Path_Params, Query_Params)) {
                context.print_style.default_format_struct.use_long_form_if_more_than_this_many_members = -1;
                log("Got members request with parameters: %", <<parameters);
                context.print_style.default_format_struct.use_long_form_if_more_than_this_many_members = 5;
                // @ToDo: reply
            });
        }
        if !success exit(1);

        if args.verbose debug_print_routes(*server);
    }

    success = start(*server, port = args.port, num_threads = args.threads);
    if !success exit(1);

    defer deinit(*server);

    log("listening on port %\n", args.port);

    while server.state != .STOPPED {
        update(*server);
        reset_temporary_storage();
    }
}

#import,file "../module.jai";

#import "Basic";

#import "Command_Line";
