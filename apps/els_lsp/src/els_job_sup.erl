
-module(els_job_sup).

-behaviour(supervisor).


%%==============================================================================
%% Exports
%%==============================================================================

%% API
-export([start_link/0]).

%% Supervisor Callbacks
-export([init/1]).

%%==============================================================================
%% Includes
%%==============================================================================
-include_lib("kernel/include/logger.hrl").

%%==============================================================================
%% Defines
%%==============================================================================

%%==============================================================================
%% API
%%==============================================================================
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%==============================================================================
%% supervisors callbacks
%%==============================================================================
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    ?LOG_DEBUG("Starting supervisor: ~p", [?MODULE]),
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 60
    },
    ChildSpecs = [
        #{
            id => els_job_exe,
            start => {els_job_exe, start_link, []},
            shutdown => brutal_kill
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
