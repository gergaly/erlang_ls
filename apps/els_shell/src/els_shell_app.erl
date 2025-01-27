-module(els_shell_app).

-behaviour(application).

-export([start/2, stop/1]).

-spec start(normal, any()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    net_kernel:start(['els_server@127.0.0.1', longnames]),
    erlang:set_cookie(split_els),
    %?LOG_INFO("Starting els_server on node: ~p, cookie: ~p", [node(),
    %                                                               split_els]),
    RemoteNode = 'fake_ls@127.0.0.1',
    net_kernel:connect_node(RemoteNode),
    net_adm:ping(RemoteNode),
    els_shell_sup:start_link().

-spec stop(any()) -> ok.
stop(_State) ->
    ok.
