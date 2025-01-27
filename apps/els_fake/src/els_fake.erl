-module(els_fake).

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

-export([call/1, cast/1]).

-export([
%    start/0,
    connect/1,
    connect2/1,
    start_server/1
%    loop/1
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("els_lsp/include/els_lsp.hrl").

-record(state, {
    buffer = <<>> :: binary(),
    connected :: pid(),
    pending = [] :: [any()]
}).

%-define(SERVER, {global, {?MODULE, node()}}).
-define(SERVER, {global, ?MODULE}).

-type state() :: #state{}.

-spec start_link() -> pid().
start_link() ->
    gen_server:start_link(?SERVER, ?MODULE, [], []).

-spec call(any()) -> any().
call(Request) ->
    gen_server:call(?SERVER, Request).

-spec cast(any()) -> any().
cast(Request) ->
    gen_server:cast(?SERVER, Request).

-spec start_server(list()) -> ok.
start_server(Args) ->
    gen_server:cast(?SERVER,{start_server, Args}).

-spec connect(pid()) -> ok.
connect(IoDevice) ->
    gen_server:cast(?SERVER,{connect, IoDevice}).

-spec connect2(pid()) -> ok.
connect2(IoDevice) ->
    gen_server:cast(?SERVER,{connect2, IoDevice}).

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
-spec init([]) -> {ok, state()}.
init([]) ->
    %process_flag(trap_exit, true),
    ?LOG_INFO("Started els_fake gen_server"),
    ?LOG_DEBUG("gl: ~p", [erlang:group_leader()]),
    State = #state{},
    {ok, State}.

-spec handle_call(any(), any(), state()) -> {reply, any(), state()}.
handle_call({state}, _From, State) ->
    {reply, {state, State}, State};
handle_call(Request, _From, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {reply, {unknown_request, Request}, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast({exit, ExitCode}, State) ->
    ?LOG_INFO("Fake language server stopping..."),
    ok = init:stop(ExitCode),
    {noreply, State};
handle_cast({send, IoDevice, Format, Payload}, State) ->
    io:format(IoDevice, Format, [Payload]),
    {noreply, State};
handle_cast({start_server, Args} = _Request, State) ->
    ?LOG_DEBUG("start_server request: ~p", [Args]),
    gen_server:cast({global, els_shell}, {start_server, Args, erlang:group_leader()}),
    {noreply, State};
handle_cast({connect, IoDevice}, State) ->
    ?LOG_DEBUG("connect request: ~p", [IoDevice]),
    {noreply, State#state{connected = IoDevice}};
handle_cast({connect2, IoDevice}, State) ->
    ?LOG_DEBUG("connect2 request: ~p", [IoDevice]),
    gen_server:cast(IoDevice, {connect, self()}),
    {noreply, State#state{connected = IoDevice}};
handle_cast({custom_request, From, Ref, Request}, State) ->
    ?LOG_DEBUG("custom_request ~p", [{From, Ref, Request}]),
    State1 = handle_locally(From, Ref, Request, State),
    State2 = process_pending(State1),
    {noreply, State2};
handle_cast(Request, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {noreply, State}.

-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info({io_request, From, Ref, Request}, State) ->
    ?LOG_DEBUG("io_request ~p", [{From, Ref, Request}]),
    State1 = dispatch(From, Ref, Request, State),
    State2 = process_pending(State1),
    {noreply, State2};
handle_info(Request, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec dispatch(pid(), any(), any(), state()) -> ok.
dispatch(From, Ref, Request, State0) ->
    case is_custom(Request) of
        true -> redirect(From, Ref, Request, State0);
        false -> handle_locally(From, Ref, Request, State0)
    end.

-spec is_custom(any()) -> boolean().
is_custom({put_chars, _Encoding, _Chars}) ->
    true;
is_custom({put_chars, _Encoding, _M, _F, _Args}) ->
    true;
is_custom(_) ->
    false.

-spec redirect(pid(), any(), any(), state()) -> state().
redirect(From, Ref, Request, State) ->
    Connected = State#state.connected,
    %Connected ! {custom_request, From, Ref, Request},
    gen_server:cast(Connected, {custom_request, From, Ref, Request}),
    State.

-spec handle_locally(pid(), any(), any(), state()) -> state().
handle_locally(From, Ref, Request, State0) ->
    case handle_request(Request, State0) of
        {noreply, State} ->
            pending(From, Ref, Request, State);
        {reply, Reply, State} ->
            reply(From, Ref, Reply),
            State
    end.

-spec handle_request(any(), state()) ->
    {reply, any(), state()} | {noreply, state()}.
handle_request({setopts, _Opts}, State) ->
    {reply, ok, State};
handle_request({put_chars, Encoding, M, F, Args}, State0) ->
    Chars = apply(M, F, Args),
    handle_request({put_chars, Encoding, Chars}, State0);
handle_request({put_chars, Encoding, Chars}, State0) ->
    EncodedChars = unicode:characters_to_list(Chars, Encoding),
    CharsBin = to_binary(EncodedChars),
    Buffer = State0#state.buffer,
    State = State0#state{buffer = <<Buffer/binary, CharsBin/binary>>},
    {reply, ok, State};
handle_request({get_line, _Encoding, _Prompt}, State0) ->
    case binary:split(State0#state.buffer, <<"\n">>, [trim]) of
        [Line0, Rest] ->
            Line = string:trim(Line0),
            {reply, <<Line/binary, "\n">>, State0#state{buffer = Rest}};
        _ ->
            {noreply, State0}
    end;
handle_request({get_chars, Encoding, _Prompt, Count}, State) ->
    handle_request({get_chars, Encoding, Count}, State);
handle_request({get_chars, _Encoding, Count}, State0) ->
    case State0#state.buffer of
        <<Data:Count/binary, Rest/binary>> ->
            {reply, Data, State0#state{buffer = Rest}};
        _ ->
            {noreply, State0}
    end.

-spec reply(pid(), any(), any()) -> any().
reply(From, ReplyAs, Reply) ->
    From ! {io_reply, ReplyAs, Reply}.

-spec pending(pid(), any(), any(), state()) -> state().
pending(From, Ref, Request, #state{pending = Pending} = State) ->
    State#state{pending = [{From, Ref, Request} | Pending]}.

-spec process_pending(state()) -> state().
process_pending(#state{pending = Pending} = State) ->
    FoldFun = fun({From, Ref, Request}, Acc) ->
        handle_locally(From, Ref, Request, Acc)
    end,
    lists:foldl(FoldFun, State#state{pending = []}, Pending).

-spec to_binary(unicode:chardata()) -> binary().
to_binary(X) when is_binary(X) ->
    X;
to_binary(X) when is_list(X) ->
    case unicode:characters_to_binary(X) of
        Result when is_binary(Result) -> Result;
        _ -> iolist_to_binary(X)
    end.

