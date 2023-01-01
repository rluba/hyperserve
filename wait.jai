Wait_Group :: struct {
    #if OS == .MACOS {
        kevent_queue: s32 = -1;
    } else #if OS == .LINUX {
        poll_fds: [..] pollfd;
        signals_by_handle: Table(s32, s32); // Map from handle to signal
    } else {
        #assert(false);
    }

    // @Speed: We could use arrays on Linux and index right into it with the poll_fds index
    fd_handlers:     Table(s32, Fd_Handler);
    signal_handlers: Table(s32, Signal_Handler);
    user_handlers:   Table(User_Event_Id, User_Handler);
}

User_Event_Id :: #type,isa u64;

Fd_Handler :: struct {
    data: *void;
    callback: #type (group: *Wait_Group, handle: s32, is_eof: bool, data: *void);
}

Signal_Handler :: struct {
    data: *void;
    callback: #type (group: *Wait_Group, signal: s32, data: *void);
}

User_Handler :: struct {
    data: *void;
    callback: #type (group: *Wait_Group, event_id: User_Event_Id, data: *void);
}


init :: (group: *Wait_Group) -> success: bool {
    #if OS == .MACOS {
        // @ToDo: This initialization itself is not thread safe
        // We could do a fancy compare_and_swap loop here like in ensure_synchronization_is_initted
        // But for now we just ensure that our first wait group is initialized before we do threaded stuff
        if next_user_event_id == 0 {
            init(*next_user_event_id_mutex);
            next_user_event_id = 1;
        }

        group.kevent_queue = kqueue();
        if group.kevent_queue == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not create event queue: % %", error_code, error_string);
            return false;
        }
    }
    return true;
}

deinit :: (group: *Wait_Group) {
    #if OS == .LINUX {
        free(group.poll_fds);
        group.poll_fds = null;
        for signal, handle: signals_by_handle {
            close_and_reset_fd(handle);
        }
        uninit(*signals_by_handle);
    } else {
        #assert(OS == .MACOS);
        close_and_reset_fd(*group.kevent_queue);
    }

    deinit(*group.fd_handlers);
    group.fd_handlers.entries.data = null;
    deinit(*group.signal_handlers);
    group.signal_handlers.entries.data = null;
    deinit(*group.user_handlers);
    group.user_handlers.entries.data = null;
}

add_handles :: (group: *Wait_Group, data: *$T, callback: #type (group: *Wait_Group, handle: s32, is_eof: bool, data: *T), handles: .. s32) -> success: bool {
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
            return false;
        }
    }

    handler: Fd_Handler;
    handler.data = data;
    handler.callback = xx callback;
    for handles {
        table_add(*group.fd_handlers, it, handler);
    }
    return true;
}

add_signals :: (group: *Wait_Group, data: *$T, callback: #type (group: *Wait_Group, signal: s32, data: *T), signals: ..s32) -> success: bool {
    #if OS == .LINUX {
        handles := NewArray(signals.count, s32, allocator = temp);
        for signals {
            handle := create_signal_handle(it);
            handles[it_index] = handle;
            table_add(*group.signals_by_handle, handle, it);
        }
        success := add_handles(group, .. handles);
        if !success return false;
    } else {
        #assert(OS == .MACOS); // @Incomplete
        events := NewArray(signals.count, Kevent64, allocator = temp);
        for signals {
            events[it_index].ident = cast(u64) it;
            events[it_index].filter = .SIGNAL;
            events[it_index].flags = .ADD;
        }
        result := kevent64(group.kevent_queue, events.data, cast (s32) events.count, null, 0, 0, null);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not register signal events with the event queue: % %", error_code, error_string);
            return false;
        }
    }

    handler: Signal_Handler;
    handler.data = data;
    handler.callback = xx callback;
    for signals {
        table_add(*group.signal_handlers, it, handler);
    }

    return true;
}

add_user_event :: (group: *Wait_Group, data: *$T, callback: #type (group: *Wait_Group, event_id: User_Event_Id, data: *T)) -> success: bool, event_id: User_Event_Id #must {
    event_id: User_Event_Id;

    #if OS == .LINUX {
        // @Incomplete: use eventfd
        assert(false);
        return false, 0;
    } else {
        #assert(OS == .MACOS); // @Incomplete
        {
            lock(*next_user_event_id_mutex);
            defer unlock(*next_user_event_id_mutex);
            event_id = next_user_event_id;
            next_user_event_id += 1;
        }

        events: [1] Kevent64;
        events[0].ident = event_id;
        events[0].filter = .USER;
        events[0].flags = .ADD;
        events[0].fflags = .FFNOP;
        result := kevent64(group.kevent_queue, events.data, cast (s32) events.count, null, 0, 0, null);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not register user event % with the event queue: % %", event_id, error_code, error_string);
            return false, 0;
        }
    }

    handler: User_Handler;
    handler.data = data;
    handler.callback = xx callback;
    table_add(*group.user_handlers, event_id, handler);

    return true, event_id;
}

trigger_user_event :: (group: *Wait_Group, event_id: User_Event_Id) -> success: bool {
    #if OS == .LINUX {
        // @Incomplete: use eventfd
        assert(false);
        return false;
    } else {
        #assert(OS == .MACOS); // @Incomplete

        events: [1] Kevent64;
        events[0].ident = event_id;
        events[0].filter = .USER;
        events[0].flags = .ENABLE;
        events[0].fflags = Kevent_Fflags.FFCOPY | .TRIGGER | 0x01;
        result := kevent64(group.kevent_queue, events.data, cast (s32) events.count, null, 0, 0, null);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not trigger user event % with the event queue: % %", event_id, error_code, error_string);
            return false;
        }
    }

    return true;
}

remove_handle :: (group: *Wait_Group, handle: s32) -> success: bool {
    table_remove(*group.fd_handlers, handle);

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
            log_error("Could not remove handle % from the event queue: % %", handle, error_code, error_string);
            return false;
        }
    }

    return true;
}

// @ToDo: remove_signal

remove_user_event :: (group: *Wait_Group, event_id: User_Event_Id) -> success: bool {
    table_remove(*group.user_handlers, event_id);

    #if OS == .LINUX {
        // @Incomplete: use eventfd
        assert(false);
        return false;
    } else {
        events: [1] Kevent64;
        events[0].ident = event_id;
        events[0].filter = .USER;
        events[0].flags = .DELETE;

        result := kevent64(group.kevent_queue, events.data, cast (s32) events.count, null, 0, 0, null);
        if result == -1 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not remove user event % from the event queue: % %", event_id, error_code, error_string);
            return false;
        }
    }

    return true;
}

// @Hack: replace is_signal with a separate" on_signal event handler?
wait_for_events :: (group: *Wait_Group, timeout_ms := -1) -> success: bool {
    success := true;

    #if OS == .LINUX {
        poll_timeout_ms := cast(s32) timeout_ms;
        num_events := poll(group.poll_fds.data, cast(u64) group.poll_fds.count, poll_timeout_ms);
        if num_events == -1 {
            error_code := System.get_error_value();
            if error_code == EINTR || error_code == EAGAIN {
                // Got interrupted, try again.
                return true;
            }

            error_string := System.get_error_string(error_code);
            log_error("Couldn't poll events: % %", error_code, error_string);
            return false, 0, 0;
        }

        for i: 0..group.poll_fds.count-1 {
            it := group.poll_fds[i];
            handle := it.fd;

            if it.revents & POLLNVAL {
                log_error("Handle % reported invalid value: %", handle, it);
                success = false;
            }

            signal := table_find_pointer(group.signals_by_handle, handle);
            if signal {
                handler := table_find_pointer(group.signal_handlers, signal);
                if handler handler.callback(group, signal, handler.data);
            } else {
                // @Incomplete: user event handlers!
                is_eof := (it.revents & POLLHUP) != 0;
                handler := table_find_pointer(group.fd_handlers, handle);
                if handler handler.callback(group, handle, is_ef, handler.data);
            }
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
            error_code := System.get_error_value();
            if error_code == EINTR || error_code == EAGAIN {
                // Got interrupted, try again.
                return true;
            }

            error_string := System.get_error_string(error_code);
            log_error("Could not read events from the event queue: % %\n", error_code, error_string);
            return false;
        }

        for 0..num_events-1 {
            event := events[it];
            if event.filter == .SIGNAL {
                signal := cast(s32) event.ident;
                handler := table_find_pointer(*group.signal_handlers, signal);
                if handler handler.callback(group, signal, handler.data);
            } else if event.filter == .READ {
                handle := cast(s32) event.ident;
                is_eof := (event.flags & .EOF) != 0;
                handler := table_find_pointer(*group.fd_handlers, handle);
                if handler handler.callback(group, handle, is_eof, handler.data);
            } else if event.filter == .USER {
                event_id := cast(User_Event_Id) event.ident;
                handler := table_find_pointer(*group.user_handlers, event_id);
                if handler handler.callback(group, event_id, handler.data);
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

#if OS == .MACOS {
    next_user_event_id_mutex: Mutex;
    next_user_event_id: User_Event_Id;
}

#if OS == .LINUX {
    create_signal_handle :: (signal: s32) -> handle: s32, success: bool {
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


