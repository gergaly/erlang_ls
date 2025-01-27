-module(fake_ls).

%%==============================================================================
%% Exports
%%==============================================================================

-export([main/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("els_lsp/include/els_lsp.hrl").

-define(DEFAULT_LOGGING_LEVEL, "info").
-define(LOG_MAX_NO_BYTES, 10 * 1000 * 1000).
-define(LOG_MAX_NO_FILES, 5).
%-define(APP, els_fake).

%%==============================================================================
%% escript callbacks
%%==============================================================================
-spec main([any()]) -> ok.
main(Args) ->
    code:add_paths(["./_build/test/lib/els_core/test"]),
    net_kernel:start(['fake_ls@127.0.0.1', longnames]),
    erlang:set_cookie(split_els),
    application:load(getopt),
    application:load(els_fake),
    ok = parse_args(Args),
    configure_logging(),
    ?LOG_INFO("Starting els_fake server on node: ~p, cookie: ~p", [node(),
                                                                   split_els]),
    RemoteNode = 'els_server@127.0.0.1',
    net_kernel:connect_node(RemoteNode),
    net_adm:ping(RemoteNode),
    els_fake:start_link(),
    %?LOG_DEBUG("global names: ~p", [global:registered_names()]),
    %timer:sleep(5000),
    ?LOG_DEBUG("global names: ~p", [global:registered_names()]),
    ShellPid = wait_for_global_pid(els_shell),
    ?LOG_DEBUG("global names: ~p", [global:registered_names()]),
    ?LOG_DEBUG("gl: ~p", [erlang:group_leader()]),
    %?LOG_DEBUG("ClientPid: ~p, ServerPid: ~p", [ClientPid, ServerPid]),
    els_fake:start_server(Args),
    receive
      _ ->
        ok
    end.

wait_for_global_pid(Name) ->
    case global:whereis_name(Name) of
        undefined ->
            timer:sleep(100),
            wait_for_global_pid(Name);
        Pid when is_pid(Pid) ->
            Pid
    end.
%%==============================================================================
%% Argument parsing
%%==============================================================================

-spec print_version() -> ok.
print_version() ->
    {ok, Vsn} = application:get_key(els_fake, vsn),
    io:format("Version: ~s~n", [Vsn]),
    ok.

-spec parse_args([string()]) -> ok.
parse_args(Args) ->
    case getopt:parse(opt_spec_list(), Args) of
        {ok, {[version | _], _BadArgs}} ->
            print_version(),
            halt(0);
        {ok, {ParsedArgs, _BadArgs}} ->
            set_args(ParsedArgs);
        {error, {invalid_option, _}} ->
            getopt:usage(opt_spec_list(), "Erlang LS"),
            halt(1)
    end.

-spec opt_spec_list() -> [getopt:option_spec()].
opt_spec_list() ->
    [
        {version, $v, "version", undefined, "Print the current version of Erlang LS"},
        {transport, $t, "transport", {string, "stdio"},
            "DEPRECATED. Only the \"stdio\" transport is currently supported."},
        {log_dir, $d, "log-dir", {string, filename:basedir(user_log, "erlang_ls")},
            "Directory where logs will be written."},
        {log_level, $l, "log-level", {string, ?DEFAULT_LOGGING_LEVEL},
            "The log level that should be used."}
    ].

-spec set_args([] | [getopt:compound_option()]) -> ok.
set_args([]) ->
    ok;
set_args([version | Rest]) ->
    set_args(Rest);
set_args([{Arg, Val} | Rest]) ->
    set(Arg, Val),
    set_args(Rest).

-spec set(atom(), getopt:arg_value()) -> ok.
set(transport, _Transport) ->
    %% Deprecated option, only kept for backward compatibility.
    ok;
set(log_dir, Dir) ->
    application:set_env(els_fake, log_dir, Dir);
set(log_level, Level) ->
    application:set_env(els_fake, log_level, list_to_atom(Level));
set(port_old, Port) ->
    application:set_env(els_fake, port, Port).

%%==============================================================================
%% Logger configuration
%%==============================================================================

-spec configure_logging() -> ok.
configure_logging() ->
    LogFile = filename:join([log_root(), "fake_ls.log"]),
    {ok, LoggingLevel} = application:get_env(els_fake, log_level),
    ok = filelib:ensure_dir(LogFile),
    [logger:remove_handler(H) || H <- logger:get_handler_ids()],
    Handler = #{
        config => #{
            file => LogFile, max_no_bytes => ?LOG_MAX_NO_BYTES, max_no_files => ?LOG_MAX_NO_FILES
        },
        level => LoggingLevel,
        formatter => {logger_formatter, #{template => ?LSP_LOG_FORMAT}}
    },
    StdErrHandler = #{
        config => #{type => standard_error},
        level => error,
        formatter => {logger_formatter, #{template => ?LSP_LOG_FORMAT}}
    },
    logger:add_handler(els_fake_handler, logger_std_h, Handler),
    logger:add_handler(els_stderr_handler, logger_std_h, StdErrHandler),
    logger:set_primary_config(level, LoggingLevel),
    ok.

-spec patch_logging() -> ok.
patch_logging() ->
    %% The ssl_handler is added by ranch -> ssl
    logger:remove_handler(ssl_handler),
    ok.

-spec log_root() -> string().
log_root() ->
    {ok, LogDir} = application:get_env(els_fake, log_dir),
    {ok, CurrentDir} = file:get_cwd(),
    Dirname = filename:basename(CurrentDir),
    filename:join([LogDir, Dirname]).

-spec cache_root() -> file:name().
cache_root() ->
    {ok, CurrentDir} = file:get_cwd(),
    Dirname = filename:basename(CurrentDir),
    filename:join(filename:basedir(user_cache, "erlang_ls"), Dirname).

-spec configure_client_logging() -> ok.
configure_client_logging() ->
    LoggingLevel = application:get_env(els_fake, log_level, notice),
    ok = logger:add_handler(
        els_log_notification,
        els_log_notification,
        #{level => LoggingLevel}
    ).
