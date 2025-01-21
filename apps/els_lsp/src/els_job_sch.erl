-module(els_job_sch).

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

-export([call/1, cast/1,
    register_worker/1,
    new_job/1
]).

-include_lib("kernel/include/logger.hrl").

-type job() ::
    #{
      config := map(),
      progress := map()
     }.

-type state() ::
    #{
      % workers
      workers := map(),
      idle := map(),
      working := map(),
      % jobs
      jobs := #{},
      % items
      pending := list()
    }.

-define(SPINNING_WHEEL_INTERVAL, 100).
%%==============================================================================
%% API
%%==============================================================================
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec call(any()) -> any().
call(Request) ->
    gen_server:call(?MODULE, Request).

-spec cast(any()) -> any().
cast(Request) ->
    gen_server:cast(?MODULE, Request).

-spec register_worker(map()) -> ok.
register_worker(Spec) ->
    cast({register_worker, Spec}).

-spec new_job(map()) -> ok.
new_job(Spec) ->
    cast({new_job, Spec}).

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
-spec init([]) -> {ok, state()}.
init([]) ->
    process_flag(trap_exit, true),
    ?LOG_INFO("Starting els_job_sch"),
    spin_up_workers(),
    State = #{
        workers => #{},
        idle => #{},
        working => #{},
        jobs => #{},
        pending => []
    },
    {ok, State}.

-spec spin_up_workers() -> ok.
spin_up_workers() ->
    Num = erlang:system_info(logical_processors_available),
    ?LOG_DEBUG("Spinning up workers: ~p", [Num]),
    [ supervisor:start_child(els_job_sup, [#{ id => Id}])
      || Id <- lists:seq(1, Num)],
    ok.

-spec handle_call(any(), any(), state()) -> {reply, any(), state()}.
handle_call({state}, _From, State) ->
    {reply, {state, State}, State};
handle_call(Request, _From, State) ->
    ?LOG_DEBUG("Unknown request ~p", [Request]),
    {reply, {unknown_request, Request}, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast({register_worker, #{id := Id, pid := Pid} = _WorkerSpec},
            #{workers := Workers, idle := Idle} = State) ->
    {noreply, State#{
        workers => maps:put(Id, Pid, Workers),
        idle => maps:put(Id, Pid, Idle)
    }};
handle_cast({new_job, Spec}, State) ->
    ?LOG_DEBUG("new_job request"),
    State1 = handle_new_job(Spec, State),
    {noreply, State1};
handle_cast({job_result, Result}, State) ->
    %?LOG_DEBUG("job_result: ~p", [Result]),
    State1 = handle_job_result(Result, State),
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

%%==============================================================================
%% internal functions
%%==============================================================================
-spec handle_job_result({integer(), pid(), any(), job(), any()}, state()) -> state().
handle_job_result({Id, Pid, Ref, #{config := _Config, progress := _Progress} = _Job, _Result},
    #{idle := Idle, working := Working, jobs := Jobs} = State) ->
    StateJob = maps:get(Ref, Jobs),
    NewWorking = maps:remove(Id, Working),
    NewIdle = maps:put(Id, Pid, Idle),
    handle_job_progress(Ref, StateJob, State#{working => NewWorking, idle => NewIdle}).

handle_job_progress(Ref,
        #{progress := #{
                current := Current0,
                total := Total,
                token := Token,
                step := Step,
                progress_enabled := ProgressEnabled,
                show_percentages := ShowPercentages
        } = Progress, config := #{on_complete := OnComplete} = Config} = Job,
        #{jobs := Jobs} = State) ->
    Current = Current0 + 1,
    NewJobs = case Current == Total of
        true ->
            %?LOG_DEBUG("job done"),
            notify_end(Token, Total, ProgressEnabled),
            ?LOG_DEBUG("Job done: ~p, ~p", [Ref, Config]),
            OnComplete({Current, 0, 0}),
            maps:remove(Ref, Jobs);
        _ ->
            %?LOG_DEBUG("job progress ~p/~p", [Current, Total]),
            Progress1 = Progress#{current => Current},
            notify_report(
                Token,
                Current,
                Step,
                Total,
                ProgressEnabled,
                ShowPercentages
            ),
            Jobs#{Ref => Job#{progress => Progress1}}
    end,
    handle_maybe_start_job(State#{jobs => NewJobs}).

-spec handle_new_job({map(), list()}, state()) -> state().
handle_new_job({_Config, [] = _Files} = _Spec, State) ->
    State;
handle_new_job({#{group := Group} = Config, Files} = _Spec,
    #{jobs := Jobs, pending := Pending} = State) ->
    Ref = make_ref(),
    %{Config, Files} = Spec,
    %#{group := Group} = Config,
    ?LOG_DEBUG("New job: ~p, ~p", [Ref, Config]),

    % progress reporting
    ProgressEnabled = els_work_done_progress:is_supported(),
    Total = length(Files),
    Step = step(Total),
    Token = els_work_done_progress:send_create_request(),
    OnComplete = maps:get(on_complete, Config, fun noop/1),
    OnError = maps:get(on_error, Config, fun noop/1),
    ShowPercentages = maps:get(show_percentages, Config, true),
    notify_begin(Token, Group, Total, ProgressEnabled, ShowPercentages),
    SpinningWheel =
        case {ProgressEnabled, ShowPercentages} of
            {true, false} ->
                spawn_link(fun() -> spinning_wheel(Token) end);
            {_, _} ->
                undefined
        end,
    Progress = #{
        on_complete => OnComplete,
        on_error => OnError,
        %progress_enabled => ProgressEnabled,
        %show_percentages => ShowPercentages,
        progress_enabled => true,
        show_percentages => true,
        token => Token,
        current => 0,
        step => Step,
        total => Total,
        internal_state => maps:get(initial_state, Config, undefined),
        spinning_wheel => SpinningWheel
    },
    Job = #{
        config => Config,
        progress => Progress
    },

    NewPending = lists:append(Pending,
        [{Ref, Job, File} || File <- Files]
    ),
    NewJobs = Jobs#{Ref => Job},

    handle_maybe_start_job(State#{jobs => NewJobs, pending => NewPending}).

%-spec cinit(config()) -> {ok, state()}.
%cinit(#{entries := Entries, title := Title} = Config) ->
%    ?LOG_DEBUG("Background job started ~s", [Title]),
%    %% Ensure the terminate function is called on shutdown, allowing the
%    %% job to clean up.
%    process_flag(trap_exit, true),
%    ProgressEnabled = els_work_done_progress:is_supported(),
%    Total = length(Entries),
%    Step = step(Total),
%    Token = els_work_done_progress:send_create_request(),
%    OnComplete = maps:get(on_complete, Config, fun noop/1),
%    OnError = maps:get(on_error, Config, fun noop/1),
%    ShowPercentages = maps:get(show_percentages, Config, true),
%    notify_begin(Token, Title, Total, ProgressEnabled, ShowPercentages),
%    SpinningWheel =
%        case {ProgressEnabled, ShowPercentages} of
%            {true, false} ->
%                spawn_link(fun() -> spinning_wheel(Token) end);
%            {_, _} ->
%                undefined
%        end,
%    self() ! exec,
%    {ok, #{
%        config => Config#{
%            on_complete => OnComplete,
%            on_error => OnError
%        },
%        progress_enabled => ProgressEnabled,
%        show_percentages => ShowPercentages,
%        token => Token,
%        current => 0,
%        step => Step,
%        total => Total,
%        internal_state => maps:get(initial_state, Config, undefined),
%        spinning_wheel => SpinningWheel
%    }}.

-spec handle_maybe_start_job(state()) -> state().
handle_maybe_start_job(
    #{pending := []} = State) ->
    State;
handle_maybe_start_job(
    #{idle := Idle} = State) when map_size(Idle) == 0 ->
    State;
handle_maybe_start_job(
    #{idle := Idle, working := Working, pending := [H|T]} = State) ->
    %?LOG_DEBUG("handle_maybe_start_job"),
    I = maps:iterator(Idle),
    {WorkerId, WorkerPid, _} = maps:next(I),
    els_job_exe:start_job(WorkerPid, H),
    NewWorking = maps:put(WorkerId, WorkerPid, Working),
    NewIdle = maps:remove(WorkerId, Idle),
    handle_maybe_start_job(State#{pending => T, working => NewWorking, idle => NewIdle}).

-spec step(pos_integer()) -> pos_integer().
step(0) -> 0;
step(N) -> 100 / N.

-spec progress_msg(non_neg_integer(), pos_integer()) -> binary().
progress_msg(Current, Total) ->
    list_to_binary(io_lib:format("~p / ~p", [Current, Total])).

-spec noop(any()) -> ok.
noop(_) ->
    ok.

-spec notify_begin(
    els_progress:token(),
    binary(),
    pos_integer(),
    boolean(),
    boolean()
) ->
    ok.
notify_begin(Token, Title, Total, true, ShowPercentages) ->
    BeginMsg = progress_msg(0, Total),
    Begin =
        case ShowPercentages of
            true -> els_work_done_progress:value_begin(Title, BeginMsg, 0);
            false -> els_work_done_progress:value_begin(Title, BeginMsg)
        end,
    els_progress:send_notification(Token, Begin);
notify_begin(_Token, _Title, _Total, false, _ShowPercentages) ->
    ok.

-spec notify_report(
    els_progress:token(),
    pos_integer(),
    pos_integer(),
    pos_integer(),
    boolean(),
    boolean()
) -> ok.
notify_report(Token, Current, Step, Total, true, true) ->
    _Step = 100 / Total,
    PrevPercentage = floor((Current - 1) * Step),
    Percentage = floor(Current * Step),
    case floor(PrevPercentage/5) =/= floor(Percentage/5) of
        true ->
            ReportMsg = progress_msg(Current, Total),
            Report = els_work_done_progress:value_report(ReportMsg, Percentage),
            els_progress:send_notification(Token, Report);
        _ ->
            ok
    end,
    ok;
notify_report(Token, Current, Step, Total, true, true) when Step >= 1 ->
    Percentage = floor(Current * Step),
    ReportMsg = progress_msg(Current, Total),
    Report = els_work_done_progress:value_report(ReportMsg, Percentage),
    els_progress:send_notification(Token, Report);
notify_report(Token, Current, Step, Total, true, true) ->
    PrevPercentage = floor((Current - 1) * Step),
    Percentage = floor(Current * Step),
    case PrevPercentage =/= Percentage of
        true ->
            ReportMsg = progress_msg(Current, Total),
            Report = els_work_done_progress:value_report(ReportMsg, Percentage),
            els_progress:send_notification(Token, Report);
        _ ->
            ok
    end,
    ok;
notify_report(
    _Token,
    _Current,
    _Step,
    _Total,
    _ProgressEnabled,
    _ShowPercentages
) ->
    ok.

-spec notify_end(els_progress:token(), pos_integer(), boolean()) -> ok.
notify_end(Token, Total, true) ->
    EndMsg = progress_msg(Total, Total),
    End = els_work_done_progress:value_end(EndMsg),
    els_progress:send_notification(Token, End);
notify_end(_Token, _Total, false) ->
    ok.

-spec spinning_wheel(els_progress:token()) -> no_return().
spinning_wheel(Token) ->
    Report = els_work_done_progress:value_report(<<>>),
    els_progress:send_notification(Token, Report),
    timer:sleep(?SPINNING_WHEEL_INTERVAL),
    spinning_wheel(Token).
