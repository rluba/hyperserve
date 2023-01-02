Request_Parameters :: struct (Path: Type = void, Query: Type = void, Payload: Type = void) {
    path:    Path;
    query:   Query;
    payload: Payload;

    // @ToDo: Optionally allow query and payload arguments not part of the types above:
    // query_extra: Table(string, string);
    // payload_extra: Table(string, string);
}

Untyped_Request_Handler :: #type (request: *Request, parameters: *void);

Route :: struct {
    path:            string;
    parameters_info: *Type_Info_Struct;
    // path_info:       *Type_Info;
    // query_info:      *Type_Info;
    // payload_info:    *Type_Info;

    handler:         Untyped_Request_Handler;
}

Route_Segment :: struct {
    literal: string;
    optional: bool;
    wildcard: bool;
}

Routing_Node :: struct {
    fixed: Table(string, Entry);
    literal: Table(string, *Routing_Node);
    wildcard: Entry;
    edge: Entry;
    parameter: *Routing_Node;
    parameter_index: int; // @ToDo: can probably be removed, using it for debugging atm

    Entry :: struct {
        parameters: [] string;
        segments: [] Route_Segment;
        route: Route;
    }
}

add_route :: (server: *Server, method: Http_Method, path: string, handler: (request: *Request, parameters: *$T/Request_Parameters)) -> bool {
    success, parameters, segments := analyze_path(path);
    if !success then return false;

    // @ToDo: Check at compile time if path parameters match $Path members, instead of doing it at runtime here
    // … but then we can’t generate paths at run-time (eg. by configuring a prefix)
    if parameters {
        Path_Type :: type_of(T.path);
        info := cast(*Type_Info_Struct) type_info(Path_Type);
        if info.type != .STRUCT {
            log_error("Path type must be a struct");
            return false;
        }
        // @ToDo: Check query and payload types

        for parameters {
            found := false;
            for member: info.members {
                if member.name == it {
                    found = true;
                    // @ToDo: Check if this member has a type that we can convert to
                    break;
                }
            }
            if !found {
                log_error("% does not have a member named \"%\"", Path_Type, it);
                return false;
            }
        }
    }

    node := find_or_add(*server.routes, method);
    return add_route(node, path, handler, parameters, segments, 0);
}

add_route :: (node: *Routing_Node, path: string, handler: (request: *Request, parameters: *$T/Request_Parameters), parameters: [] string, segments: [] Route_Segment, parameter_index: int) -> bool {
    // @ToDo: This is silly! Create this once and pass it through!
    entry: Routing_Node.Entry;
    entry.parameters = parameters;
    entry.segments = segments;
    entry.route.path = path;
    entry.route.parameters_info = type_info(T);
    // entry.route.path_info = type_info(T.path);
    // entry.route.query_info = type_info(T.query);
    // entry.route.payload_info = type_info(T.payload);
    entry.route.handler = xx handler;

    if parameters.count == parameter_index {
        // Fully literal

        length := 0;
        for segments {
            assert(it.literal != "");
            length += it.literal.count + 1;
        }
        if length == 0 then length = 1;
        literal := slice(path, path.count - length, length);

        // builder: String_Builder;
        // for segments {
        //     assert(it.literal);
        //     append(*builder, #char "/");
        //     append(*builder, it.literal);
        // }
        // literal := builder_to_string(*builder);
        // if !literal then literal = "/";

        existing := table_find_pointer(*node.fixed, literal);
        if existing {
            log_error("Route \"%\" conflicts with route \"%\"", path, existing.route.path);
            return false;
        }

        table_add(*node.fixed, literal, entry);
        return true;
    } else {
        assert(segments.count > 0);
        current := segments[0];
        remaining := array_view(segments, 1, segments.count - 1);
        if current.literal {
            // Literal segment with parameters further down
            sub_node_pointer := find_or_add(*node.literal, current.literal);
            if !(<<sub_node_pointer) {
                <<sub_node_pointer = New(Routing_Node);
            }
            return add_route(<<sub_node_pointer, path, handler, parameters, remaining, parameter_index);
        } else if current.wildcard {
            // Wildcard route
            if node.wildcard.route.path {
                log_error("Route \"%\" conflicts with route \"%\"", path, node.wildcard.route.path);
                return false;
            }

            if node.parameter && node.parameter.wildcard.route.path {
                log_error("Route \"%\" conflicts with route \"%\"", path, node.parameter.wildcard.route.path);
                return false;
            }
            node.wildcard = entry;
            return true;
        // } else if "prefix/suffix case" {
        } else {
            // Edge
            if remaining {
                if node.wildcard.route.path {
                    log_error("Route \"%\" conflicts with route \"%\"", path, node.wildcard.route.path);
                    return false;
                }
                if !node.parameter {
                    node.parameter = New(Routing_Node);
                }
                node.parameter_index = parameter_index;

                return add_route(node.parameter, path, handler, parameters, remaining, parameter_index + 1);
            } else {
                if node.edge.route.path {
                    log_error("Route \"%\" conflicts with route \"%\"", path, node.edge.route.path);
                    return false;
                }
                node.edge = entry;
                return true;
            }
        }
    }
}

analyze_path :: (path: string) -> success: bool, parameters: [] string = .[], segments: [] Route_Segment = .[] {
    if !path || path[0] != #char "/" {
        log_error("Route path must begin with \"/\"");
        return false;
    }

    parameters: [..] string;
    segments: [..] Route_Segment;

    found: bool;
    part: string;
    path_remainder := slice(path, 1, path.count - 1);
    while path_remainder {
        found, part, path_remainder = split_from_left(path_remainder, #char "/");
        param_found, prefix, remainder := split_from_left(part, #char "{");
        segment: Route_Segment;
        if param_found {
            if prefix != "" {
                log_error("Parameters with a string prefix are not yet supported! (Found in part \"%\" of \"%\")", part, path);
                return false;
            }

            parameter: string;
            found, parameter, remainder = split_from_left(remainder, #char "}");
            if !found {
                log_error("Missing \"}\" for parameter declaration in part \"%\" of \"%\"", part, path);
                return false;
            }
            if remainder != "" {
                log_error("Parameters with a string suffix are not yet supported! (Found in part \"%\" of \"%\")", part, path);
                return false;
            }

            if parameter && parameter[parameter.count - 1] == #char "?" {
                assert(false, "@Incomplete: The routing table doesn’t handle optional paths yet…");
                segment.optional = true;
                parameter.count -= 1;
            }
            if parameter && parameter[parameter.count - 1] == #char "*" {
                segment.wildcard = true;
                parameter.count -= 1;
            }

            if !parameter {
                log_error("Missing parameter name in part \"%\" of \"%\"", part, path);
                return false, .[], .[];
            }

            for i: 0..parameter.count-1 {
                c := parameter[i];
                if c != #char "_" && !is_alpha(c) && (i == 0 || !is_digit(c)) {
                    log_error("Illegal character \"%\" at position % in parameter name \"%\" in part \"%\" of \"%\"", slice(parameter, i, 1), i, parameter, part, path);
                    return false;
                }
            }

            if array_find(parameters, parameter) {
                log_error("Duplicate parmeter name \"%\" in \"%\"", parameter, path);
                return false;
            }

            array_add(*parameters, parameter);
        } else {
            segment.literal = to_lower_copy(part);
        }
        array_add(*segments, segment);
    }

    return true, parameters, segments;
}
