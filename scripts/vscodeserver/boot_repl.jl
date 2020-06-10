# this script basially only handles `Base.ARGS`

Base.push!(LOAD_PATH, @__DIR__)
using VSCodeServer
pop!(LOAD_PATH)

# load Revise ?
if "USE_REVISE" in Base.ARGS
    try
        @eval using Revise
        Revise.async_steal_repl_backend()
    catch err
        @warn "failed to load Revise: $err"
    end
end

"USE_PLOTPANE" in Base.ARGS && Base.Multimedia.pushdisplay(VSCodeServer.InlineDisplay())

let
    # TODO: enable telemetry here again
    conn_pipeline, telemetry_pipeline = Base.ARGS[1:2]
    VSCodeServer.serve(conn_pipeline; is_dev = "DEBUG_MODE" in Base.ARGS)
end