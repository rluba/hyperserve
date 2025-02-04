SSE_Handle :: struct {
    request  : *Request;
    mutex    : Mutex;
    event_id : User_Event_Id;
}

initialize_sse_event_stream :: () -> *SSE_Handle
{
    using context.hyperserve;

    /*****************************
    * initialize the SSE handler *
    *****************************/

    sse_handle := New(SSE_Handle);
    sse_handle.request = request;
    init(*sse_handle.mutex);
    success: bool;
    success, sse_handle.event_id = add_user_event(*server.wait_group, sse_handle, user_send_sse_data);
    if !success return null;

    /*************************************
    * send the SSE headers to the client *
    *************************************/

    SSE_HEADERS :: Response_Header.[
        .{
            name  = "Cache-Control",
            value = "no-cache",
        },
        .{
            name  = "Connection",
            value = "keep-alive",
        },
    ];

    builder: String_Builder;
    if !begin_response(*builder, content_length = 0, status_code = 200, content_type = "text/event-stream", headers = SSE_HEADERS)
    {
        log_error("Could not send SSE headers");
        return null;
    }
    send_sse_event(sse_handle, *builder);

    request.phase = .SENDING_RESPONSE; // TODO: is this necessary?

    return sse_handle;
}

send_sse_event :: (sse_handle: SSE_Handle, event_builder: *String_Builder) -> bool
{
    if get_base_buffer(event_builder).count == 0 return false; // nothing to send

    using context.hyperserve;

    lock(*sse_handle.mutex);
    defer unlock(*sse_handle.mutex);

    response_was_empty := get_base_buffer(*request.response_builder).count == 0;
    append_and_steal_buffers(*request.response_builder, event_builder);
    // if the response was empty, we need to trigger a user event to send the response.
    //
    // if it is empty, some other call to this function has already appended to response_builder
    // and triggered the user event, and the user handler func has yet to take the lock and start
    // sending the response. since we already appended this sse event to the response_builder, we
    // can just return since the previously-triggered user handler will handle the sending for us.
    if response_was_empty
    {
        return trigger_user_event(*server.wait_group, sse_handle.event_id);
    }
    return true;
}

user_send_sse_data :: (group: *Wait_Group, event_id: User_Event_Id, sse_handle: *SSE_Handle)
{
    lock(*sse_handle.mutex);
    defer unlock(*sse_handle.mutex);

    request := sse_handle.request;
    push_allocator(pool_allocator_proc, request.pool);
    client := request.client;
    socket := request.client.socket;

    flags: MSG;
    #if OS == .LINUX {
        flags |= .NOSIGNAL;
    }

    current_response_buffer := get_base_buffer(*request.response_builder);
    current_response_buffer_offset := 0;
    total_bytes_sent := 0;
    while current_response_buffer {
        data := get_buffer_data(current_response_buffer) + current_response_buffer_offset;
        remaining := current_response_buffer.count - current_response_buffer_offset;
        while remaining {
            result := send(socket, data, cast(u64) remaining, flags);
            if result == -1 {
                error_code := get_last_socket_error();
                if error_code == EAGAIN || error_code == EWOULDBLOCK {
                    return; // Wait until we’re called again, when there’s more room.
                }

                error_string := System.get_error_string(error_code);
                log_error("Could not send response (after % bytes already sent): % %", total_bytes_sent, error_code, error_string);
                return;
            }

            assert(result <= remaining);
            data += result;
            current_response_buffer_offset += result;
            remaining -= result;
            total_bytes_sent += result;
        }

        current_response_buffer = current_response_buffer.next;
        current_response_buffer_offset = 0;
    }

    reset(*request.response_builder);
}
