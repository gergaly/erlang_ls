-module(els_shell).

-behaviour(gen_server).

%%==============================================================================
%% Exports
%%==============================================================================

-export([start_link/0]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-export([s/0, start_lsp/0, start_lsp/1, send/1, call/1, cast/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("els_lsp/include/els_lsp.hrl").

-type state() ::
    #{
    }.

-define(DEFAULT_LOGGING_LEVEL, "info").
-define(LOG_MAX_NO_BYTES, 10 * 1000 * 1000).
-define(LOG_MAX_NO_FILES, 5).
%%==============================================================================
%% API
%%==============================================================================
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

s() ->
    els_shell:start_lsp(),
    timer:sleep(500),
    RootUri = els_uri:uri(els_utils:to_binary("/home/ebertge/priv/berlangls")),
    %RootUri = els_uri:uri(els_utils:to_binary("/home/ebertge/work/vsbg")).
    els_client:initialize(RootUri),
    timer:sleep(500),
    els_indexing:start2(),
    ok.

-spec start_lsp() -> ok.
start_lsp() ->
    start_lsp("-l debug -d ./").

-spec start_lsp(string()) -> ok.
start_lsp(Args) ->
    gen_server:cast(?MODULE, {start_lsp_split, Args}).

-spec call(any()) -> any().
call(Request) ->
    gen_server:call(?MODULE, Request).

-spec cast(any()) -> any().
cast(Request) ->
    gen_server:cast(?MODULE, Request).

-spec send(any()) -> ok.
send(Req) ->
    ?MODULE ! Req,
    ok.

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
-spec init([]) -> {ok, state()}.
init([]) ->
    process_flag(trap_exit, true),
    ?LOG_INFO("Starting els_shell..."),
    State = #{
        index_dir => [],
        group_leader => undefined
    },
    {ok, State}.

-spec handle_call(any(), any(), state()) -> {reply, any(), state()}.
handle_call({state}, _From, State) ->
    {reply, {state, State}, State};
handle_call({group_leader}, _From, #{group_leader := GL} = State) ->
    {reply, GL, State};
handle_call(Request, _From, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {reply, {unknown_request, Request}, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast({start_server, Args, GL}, State) ->
    handle_start_server(Args, GL),
    {noreply, State#{group_leader => GL}};
handle_cast({start_lsp, Args}, State) ->
    handle_start_lsp(Args),
    {noreply, State};
handle_cast({start_lsp_split, Args}, State) ->
    handle_start_lsp_split(Args),
    {noreply, State};
handle_cast(Request, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {noreply, State}.

-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info({index_dir, Dir, Res}, #{index_dir := IndexDir} = State) ->
    {noreply, State#{index_dir => lists:append(IndexDir, [{Dir, Res}])}};
handle_info(Request, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec handle_start_lsp_split(string()) -> pid().
handle_start_lsp_split(Args) ->
    ok = erlang_ls:parse_args(Args),
    application:set_env(els_core, server, els_server),
    configure_logging(),
    ?LOG_DEBUG("Started els_server in split mode"),
    ok.

-spec handle_start_server(string(), pid()) -> pid().
handle_start_server(Args, GL) ->
    code:add_paths(["./_build/test/lib/els_core/test"]),
    ok = erlang_ls:parse_args(Args),
    application:set_env(els_core, server, els_server),
    configure_logging(),
    ok = application:set_env(els_core, io_device, standard_io, [persistent, true]),
    ok = application:set_env(els_core, mode, split, [persistent, true]),
    ok = application:set_env(els_core, gl, GL, [persistent, true]),
    {ok, _} = application:ensure_all_started(els_lsp, permanent),
    patch_logging(),
    % erlang_ls:configure_client_logging(),
    %{ok, ClientPid} = els_client:start_link(#{io_device => ClientIo}),
    ?LOG_INFO("Started erlang_ls server", []),
    %ClientPid.
    ok.

-spec handle_start_lsp(string()) -> pid().
handle_start_lsp(Args) ->
    code:add_paths(["./_build/test/lib/els_core/test"]),
    ok = erlang_ls:parse_args(Args),
    application:set_env(els_core, server, els_server),
    configure_logging(),
    ClientIo = els_fake_stdio:start(),
    ServerIo = els_fake_stdio:start(),
    els_fake_stdio:connect(ClientIo, ServerIo),
    els_fake_stdio:connect(ServerIo, ClientIo),
    ok = application:set_env(els_core, io_device, ServerIo, [persistent, true]),
    {ok, _} = application:ensure_all_started(els_lsp, permanent),
    patch_logging(),
    % erlang_ls:configure_client_logging(),
    {ok, ClientPid} = els_client:start_link(#{io_device => ClientIo}),
    ?LOG_INFO("Started erlang_ls server", []),
    ClientPid.

%%==============================================================================
%% Logger configuration
%%==============================================================================

-spec configure_logging() -> ok.
configure_logging() ->
    LogFile = filename:join([log_root(), "server.log"]),
    {ok, LoggingLevel} = application:get_env(els_core, log_level),
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
        level => debug,
        formatter => {logger_formatter, #{template => ?LSP_LOG_FORMAT}}
    },
    logger:add_handler(els_core_handler, logger_std_h, Handler),
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
    {ok, LogDir} = application:get_env(els_core, log_dir),
    {ok, CurrentDir} = file:get_cwd(),
    Dirname = filename:basename(CurrentDir),
    filename:join([LogDir, Dirname]).

