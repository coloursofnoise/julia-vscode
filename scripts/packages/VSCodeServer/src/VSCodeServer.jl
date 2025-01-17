module VSCodeServer

export vscodedisplay, @enter, @run
export view_profile, @profview

using REPL, Sockets, Base64, Pkg, UUIDs
import Base: display, redisplay
import Dates
import Profile
import Logging

function __init__()
    atreplinit() do repl
        @async try
            hook_repl(repl)
        catch err
            Base.display_error(err, catch_backtrace())
        end
    end

    push!(Base.package_callbacks, pkgload)
end

include("../../JSON/src/JSON.jl")
include("../../CodeTracking/src/CodeTracking.jl")

module JSONRPC
    import ..JSON
    import UUIDs

    include("../../JSONRPC/src/packagedef.jl")
end

module JuliaInterpreter
    using ..CodeTracking

    include("../../JuliaInterpreter/src/packagedef.jl")
end

module DebugAdapter
    import ..JuliaInterpreter
    import ..JSON
    import ..JSONRPC
    import ..JSONRPC: @dict_readable, Outbound

    include("../../DebugAdapter/src/packagedef.jl")
end

module ChromeProfileFormat
    import ..JSON
    import Profile

    include("../../ChromeProfileFormat/src/core.jl")
end

const conn_endpoint = Ref{Union{Nothing,JSONRPC.JSONRPCEndpoint}}(nothing)

include("../../../error_handler.jl")
include("repl_protocol.jl")
include("misc.jl")
include("trees.jl")
include("gridviewer.jl")
include("module.jl")
include("progress.jl")
include("eval.jl")
include("repl.jl")
include("display.jl")
include("profiler.jl")
include("debugger.jl")

function dispatch_msg(conn_endpoint, msg_dispatcher, msg, is_dev)
    if is_dev
        try
            JSONRPC.dispatch_msg(conn_endpoint[], msg_dispatcher, msg)
        catch err
            Base.display_error(err, catch_backtrace())
        end
    else
        JSONRPC.dispatch_msg(conn_endpoint[], msg_dispatcher, msg)
    end
end

is_disconnected_exception(err) = err isa InvalidStateException && err.state === :closed || err isa Base.IOError

function serve(args...; is_dev=false, crashreporting_pipename::Union{AbstractString,Nothing}=nothing)
    @debug "connecting to pipe"
    conn = connect(args...)
    conn_endpoint[] = JSONRPC.JSONRPCEndpoint(conn, conn)
    @debug "connected"
    if EVAL_BACKEND_TASK[] === nothing
        start_eval_backend()
    end
    run(conn_endpoint[])
    @debug "running"

    @async try
        msg_dispatcher = JSONRPC.MsgDispatcher()

        msg_dispatcher[repl_runcode_request_type] = repl_runcode_request
        msg_dispatcher[repl_interrupt_notification_type] = repl_interrupt_request
        msg_dispatcher[repl_getvariables_request_type] = repl_getvariables_request
        msg_dispatcher[repl_getlazy_request_type] = repl_getlazy_request
        msg_dispatcher[repl_showingrid_notification_type] = repl_showingrid_notification
        msg_dispatcher[repl_loadedModules_request_type] = repl_loadedModules_request
        msg_dispatcher[repl_isModuleLoaded_request_type] = repl_isModuleLoaded_request
        msg_dispatcher[repl_startdebugger_notification_type] = (conn, params) -> repl_startdebugger_request(conn, params, crashreporting_pipename)
        msg_dispatcher[repl_toggle_plot_pane_notification_type] = toggle_plot_pane
        msg_dispatcher[repl_toggle_progress_notification_type] = toggle_progress
        msg_dispatcher[cd_notification_type] = cd_to_uri
        msg_dispatcher[activate_project_notification_type] = activate_uri
        msg_dispatcher[repl_getdebugitems_request_type] = debugger_getdebugitems_request

        @sync while conn_endpoint[] isa JSONRPC.JSONRPCEndpoint && isopen(conn)
            msg = JSONRPC.get_next_message(conn_endpoint[])

            if msg["method"] == repl_runcode_request_type.method
                @async dispatch_msg(conn_endpoint, msg_dispatcher, msg, is_dev)
            else
                dispatch_msg(conn_endpoint, msg_dispatcher, msg, is_dev)
            end
        end
    catch err
        if !isopen(conn) && (
             err isa CompositeException && all(is_disconnected_exception, err.exceptions) ||
             is_disconnected_exception(err)
           )
            # expected error
            @debug "remote closed the connection"
        else
            try
                global_err_handler(err, catch_backtrace(), crashreporting_pipename, "REPL")
            catch err
                @error "Error handler threw an error." exception=(err, catch_backtrace())
            end
        end
    finally
        @debug "JSONRPC dispatcher task finished"
    end
end

end  # module
