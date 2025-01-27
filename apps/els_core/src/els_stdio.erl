-module(els_stdio).

-export([
    start_listener/3,
    init/1,
    send/3
]).

-export([loop_local/4, loop_remote/4]).

%%==============================================================================
%% Includes
%%==============================================================================
-include_lib("kernel/include/logger.hrl").

%%==============================================================================
%% els_transport callbacks
%%==============================================================================
-spec start_listener(function()|undefined, node()|undefined, pid()) -> {ok, pid()}.
start_listener(Cb, undefined, _) ->
    IoDevice = application:get_env(els_core, io_device, standard_io),
    {ok, proc_lib:spawn_link(?MODULE, init, [{Cb, IoDevice, undefined}])};
start_listener(_, FakePid, ServerPid) ->
    Node = node(FakePid),
    {ok, proc_lib:spawn_link(Node, ?MODULE, init, [{undefined, standard_io,
                                                    ServerPid}])}.


-spec init({function()|undefined, atom() | pid(), pid()|undefined}) -> no_return().
init({Cb, IoDevice, undefined}) ->
    ?LOG_INFO("Starting stdio server... [io_device=~p]", [IoDevice]),
    ok = io:setopts(IoDevice, [binary, {encoding, latin1}]),
    {ok, Server} = application:get_env(els_core, server),
    ok = Server:set_io_device(IoDevice),
    ?MODULE:loop_local([], IoDevice, Cb, fun json:decode/1);
init({undefined, IoDevice, ServerPid}) ->
    case global:whereis_name(els_shell) of
        ShellPid when is_pid(ShellPid) ->
            GL = gen_server:call({global, els_shell}, {group_leader}),
            erlang:group_leader(GL, self())
    end,
    ?LOG_INFO("Starting stdio server... [io_device=~p]", [IoDevice]),
    ok = io:setopts(IoDevice, [binary, {encoding, latin1}]),
    ?MODULE:loop_remote([], IoDevice, ServerPid, fun json:decode/1).

-spec send(atom() | pid(), pid() | undefined, binary()) -> ok.
send(IoDevice, undefined, Payload) ->
    io:format(IoDevice, "~s", [Payload]);
send(IoDevice, _StdioPid, Payload) ->
    gen_server:cast({global, els_fake}, {send, IoDevice, "~s", Payload}).

%%==============================================================================
%% Listener loop function
%%==============================================================================

-spec loop_local([binary()], any(), function(), fun()) -> no_return().
loop_local(Lines, IoDevice, Cb, JsonDecoder) ->
    case io:get_line(IoDevice, "") of
        <<"\n">> ->
            Headers = parse_headers(Lines),
            BinLength = proplists:get_value(<<"content-length">>, Headers),
            Length = binary_to_integer(BinLength),
            %% Use file:read/2 since it reads bytes
            {ok, Payload} = file:read(IoDevice, Length),
            Request = JsonDecoder(Payload),
            Cb([Request]),
            ?MODULE:loop_local([], IoDevice, Cb, JsonDecoder);
        eof ->
            Cb([
                #{
                    <<"method">> => <<"exit">>,
                    <<"params">> => []
                }
            ]);
        Line ->
            ?MODULE:loop_local([Line | Lines], IoDevice, Cb, JsonDecoder)
    end.

-spec loop_remote([binary()], any(), pid(), fun()) -> no_return().
loop_remote(Lines, IoDevice, ServerPid, JsonDecoder) ->
    case io:get_line(IoDevice, "") of
        <<"\n">> ->
            Headers = parse_headers(Lines),
            BinLength = proplists:get_value(<<"content-length">>, Headers),
            Length = binary_to_integer(BinLength),
            %% Use file:read/2 since it reads bytes
            {ok, Payload} = file:read(IoDevice, Length),
            Request = JsonDecoder(Payload),
            gen_server:cast(ServerPid, {process_requests, [Request]}),
            ?MODULE:loop_remote([], IoDevice, ServerPid, JsonDecoder);
        eof ->
            Request = [
                #{
                    <<"method">> => <<"exit">>,
                    <<"params">> => []
                }
            ],
            gen_server:cast(ServerPid, {process_requests, Request});
        Line ->
            ?MODULE:loop_remote([Line | Lines], IoDevice, ServerPid, JsonDecoder)
    end.

-spec parse_headers([binary()]) -> [{binary(), binary()}].
parse_headers(Lines) ->
    [parse_header(Line) || Line <- Lines].

-spec parse_header(binary()) -> {binary(), binary()}.
parse_header(Line) ->
    [Name, Value] = binary:split(Line, <<":">>),
    {string:trim(string:lowercase(Name)), string:trim(Value)}.
