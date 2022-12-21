Args :: struct {
    port: u16 = 80;
    verbose: bool;
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

    using context.hyperserve;
    server.verbose = args.verbose;

    {
        success := add_route(*server, .GET, "/", (request: *Request, parameters: *Request_Parameters(void, void, void)) {
            log("Got root request!");
            respond("pretend this is index.html", content_type = "text/html");
        });
        success &= add_route(*server, .POST, "/", (request: *Request, parameters: *Request_Parameters(void, void, void)) {
            log("Got root POST!");
            respond("Something was wrong with your post", 422);
        });
        success &= add_route(*server, .GET, "/long/path/but/no/params", (request: *Request, parameters: *Request_Parameters(void, void, void)) {
            log("Got long path request!");
            // @ToDo: reply
        });
        success &= add_route(*server, .GET, "/{prefix}/long/path/but/no/more/params", (request: *Request, parameters: *Request_Parameters(struct {prefix: string;}, void, void)) {
            log("Got long path request with prefix: %!", request.url);
            // @ToDo: reply
        });
        success &= add_route(*server, .GET, "/{path}", (request: *Request, parameters: *Request_Parameters(struct {path: string;}, void, void)) {
            log("Got path request: %", request.url);
            // @ToDo: reply
        });
        success &= add_route(*server, .GET, "/ping", (request: *Request, parameters: *Request_Parameters(void, void, void)) {
            log("Got ping request!");
            // @ToDo: reply
        });
        success &= add_route(*server, .GET, "/ping/{path*}", (request: *Request, parameters: *Request_Parameters(struct {path: string;}, void, void)) {
            log("Got ping request with path: %", request.url);
            // @ToDo: reply
        });
        success &= add_route(*server, .GET, "/members/{id}/upload/{upload_id}/{path*}", (request: *Request, parameters: *Request_Parameters(struct {id: int; upload_id: int; path: string;}, void, void)) {
            log("Got members request with path: %", request.url);
            // @ToDo: reply
        });
        if !success exit(1);

        debug_print_routes(*server);
    }

    success = listen(*server, port = args.port);
    if !success exit(1);

    log("listening on port %\n", args.port);

    while !server.should_quit {
        update(*server);
    }

    deinit(*server);
}

#import,file "../module.jai";

#import "Basic";
#import "Socket";

#import "Command_Line";
#import "Hash_Table";
