
-module(els_job_exe).

-behaviour(gen_server).

%%==============================================================================
%% Exports
%%==============================================================================

-export([start_link/1]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-export([start_job/2]).

-include_lib("kernel/include/logger.hrl").

-type state() ::
    #{
      id := integer()
    }.

%%==============================================================================
%% API
%%==============================================================================
-spec start_link(list()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec start_job(pid(), map()) -> ok.
start_job(Pid, Job) ->
    gen_server:cast(Pid, {start_job, Job}).

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
-spec init([]) -> {ok, state()}.
init(#{id := Id} = Args) ->
    process_flag(trap_exit, true),
    ?LOG_INFO("Starting els_job_exe, args: ~p", [Args]),
    els_job_sch:register_worker(#{id => Id, pid => self()}),
    State = #{
        id => Id
    },
    {ok, State}.

-spec handle_call(any(), any(), state()) -> {reply, any(), state()}.
handle_call(Request, _From, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {reply, {unknown_request, Request}, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast({start_job, Job}, State) ->
    %?LOG_DEBUG("starting job ~p", [Job]),
    State1 = handle_job(Job, State),
    {noreply, State1};
handle_cast(Request, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {noreply, State}.

-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info(Request, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec handle_job(any(), state()) -> state().
handle_job({Ref, #{config := #{task := Task} = _Config } = Job, File}, #{id := Id} = State) ->
    Result = Task(File),
    els_job_sch:cast({job_result, {Id, self(), Ref, Job, Result}}),
    State.

