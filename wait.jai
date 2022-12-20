Wait_Group :: struct {
    #if OS == .MACOS {
        kevent_queue: s32 = -1;
    } else #if OS == .LINUX {
        poll_fds: [..] pollfd;
    } else {
        #assert(false);
    }
}

// @ToDo: Wait for write?
init :: (group: *Wait_Group, handles: .. s32) -> success: bool {
    #if OS == .MACOS {
        group.kevent_queue = kqueue();
        if group.kevent_queue == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not create event queue: % %", error_code, error_string);
            deinit(group);
            return false;
        }
    }
    return true;
}

add_handles :: (group: *Wait_Group, handles: .. s32) -> success: bool {
    #if OS == .LINUX {
        array_reserve(*group.poll_fds, *group.poll_fds.count + handles.count);
        for handles {
            fd: poll_fds;
            fd.fd = it;
            fd.events = POLLIN;
            array_add(*group.poll_fds, fd);
        }
    } else {
        events := NewArray(handles.count, Kevent64, allocator = temp);
        for handles {
            events[it_index].ident = cast(u64) it;
            events[it_index].filter = .READ;
            events[it_index].flags = .ADD;
        }

        result := kevent64(group.kevent_queue, events.data, cast (s32) events.count, null, 0, 0, null);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not register events with the event queue: % %", error_code, error_string);
            deinit(group);
            return false;
        }
    }

    return true;
}

remove_handle :: (group: *Wait_Group, handle: s32) -> success: bool {
    #if OS == .LINUX {
        for handles {
            if it.fd == handle {
                remove it;
                return true;
            }
        }
        log_error("Could not find handle % to remove it from the watch group.", handle);
        return false;
    } else {
        events: [1] Kevent64;
        events[0].ident = cast(u64) handle;
        events[0].filter = .READ;
        events[0].flags = .DELETE;

        result := kevent64(group.kevent_queue, events.data, cast (s32) events.count, null, 0, 0, null);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not remove handle % with the event queue: % %", handle, error_code, error_string);
            deinit(group);
            return false;
        }
    }

    return true;
}

deinit :: (group: *Wait_Group) {
    #if OS == .LINUX {
        free(group.poll_fds);
        group.poll_fds = null;
    } else {
        #assert(OS == .MACOS);
        close_and_reset_fd(*group.kevent_queue);
    }
}

wait_for_events :: (group: *Wait_Group, data: $T, on_event: #type (handle: s32, is_eof: bool, data: T), timeout_ms := -1) -> success: bool {
    success := true;

    #if OS == .LINUX {
        poll_timeout_ms := cast(s32) timeout_ms;
        num_events := poll(group.poll_fds.data, cast(u64) group.poll_fds.count, poll_timeout_ms);
        if num_events == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Couldn't poll events: % %", error_code, error_string);
            return false, 0, 0;
        }

        // log("% poll events for %: %", num_events, <<process, poll_fds);

        for i: 0..group.poll_fds.count-1 {
            it := group.poll_fds[i];
            handle := it.fd; 
            pipe: *Process.Pipe;
            if handle == process.output.handle {
                pipe = *process.output;
            } else {
                assert(handle == process.error.handle);
                pipe = *process.error;
            }

            if it.revents & POLLNVAL {
                log_error("Pipe % of % reported invalid value: %", <<pipe, <<process, it);
                success = false;
            }

            read_success: bool;
            is_eof := (it.revents & POLLHUP) != 0;
            on_event(handle, is_eof, data);
        }
    } else {
        #assert(OS == .MACOS);

        timeout_spec_pointer: *timespec = null;
        timeout_spec: timespec;
        if timeout_ms >= 0 {
            timeout_spec.tv_sec = timeout_ms / 1000;
            timeout_spec.tv_nsec = (timeout_ms % 1000) * 1000 * 1000;
            timeout_spec_pointer = *timeout_spec;
        }

        // @ToDo: Max events?
        events: [2] Kevent64;
        num_events := kevent64(group.kevent_queue, null, 0, events.data, events.count, 0, timeout_spec_pointer);
        if num_events == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not read events from the event queue: % %\n", error_code, error_string);
            return false;
        }

        for 0..num_events-1 {
            event := events[it];
            if event.filter == .READ {
                handle := cast(s32) event.ident;
                is_eof := (event.flags & .EOF) != 0;
                on_event(handle, is_eof, data);
            }
        }
    }

    return success;
}

close_and_reset_fd :: (fd: *s32, loc := #caller_location) {
    if <<fd != -1 {
        result := close(<<fd);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("%: %,%: Could not close file descriptor %: % %", loc.fully_pathed_filename, loc.line_number, loc.character_number, fd, error_code, error_string);
        }
        <<fd = -1;
    }
}

#scope_file

#if OS == .LINUX {
    create_signal_handler :: (signal: s32) -> handle: s32, success: bool {
        sig_mask: sigset_t;
        sigemptyset(*sig_mask);
        sigaddset(*sig_mask, signal);

        result := sigprocmask(SIG_BLOCK, *sig_mask, null);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Couldn’t set sigprocmask for event %: % %", signal, error_code, error_string);
            return HANDLE_INVALID, false;
        }

        return signalfd(-1, *sig_mask, 0), true;
    }
} else #if OS == .MACOS {
    #import "macos";
}


