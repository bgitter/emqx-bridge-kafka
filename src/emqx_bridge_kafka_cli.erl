%%%-------------------------------------------------------------------
%%% @author zxb
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 22. 4月 2020 上午11:17
%%%-------------------------------------------------------------------
-module(emqx_bridge_kafka_cli).
-author("zxb").

-include_lib("emqx/include/logger.hrl").

-logger_header("[bridge kafka cli]").

%% API
-export([load/0, unload/0, kafka_stats/1]).

load() ->
  ?LOG(info, "load..."),
  emqx_ctl:register_command(kafka_stats, {emqx_bridge_kafka_cli, kafka_stats}, []).

kafka_stats([]) ->
  lists:foreach(
    fun({Stats, Val}) ->
      io:format("~-20s: ~w~n", [Stats, Val])
    end, maps:to_list(wolff_stats:get_stats()));
kafka_stats(_) ->
  [io:format("~-48s# ~s~n", [Cmd, Desc]) || {Cmd, Desc} <- [{"kafka_stats", "Bridge kafka message stats"}]].

unload() ->
  ?LOG(info, "unload..."),
  emqx_ctl:unregister_command(kafka_stats).
