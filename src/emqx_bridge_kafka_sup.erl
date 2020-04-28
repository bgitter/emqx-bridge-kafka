%%%-------------------------------------------------------------------
%% @doc emqx_bridge_kafka top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(emqx_bridge_kafka_sup).

-behaviour(supervisor).

-include_lib("emqx/include/logger.hrl").

-logger_header("[bridge kafka sup]").

-export([start_link/0]).

-export([init/1]).

start_link() ->
  ?LOG(info, "start link..."),
  supervisor:start_link({local, emqx_bridge_kafka_sup}, emqx_bridge_kafka_sup, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
  ?LOG(info, "init..."),
  SupFlags = #{strategy => one_for_one,
    intensity => 10,
    period => 100},
  ChildSpecs = [],
  {ok, {SupFlags, ChildSpecs}}.
