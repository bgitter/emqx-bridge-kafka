%%%-------------------------------------------------------------------
%%% @author zxb
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 03. 6月 2020 上午10:03
%%%-------------------------------------------------------------------
-module(emqx_bridge_kafka_koc).
-author("zxb").

-include_lib("emqx/include/logger.hrl").

-logger_header("[emqx bridge kafka koc]").

%% API
-export([
  load/0
]).


load() ->
  emqx_logger:set_log_level(info),
  {ok, _AppNames} = application:ensure_all_started(emqx_bridge_kafka),
  ?LOG(info, "~p~n", [_AppNames]),
  ok.