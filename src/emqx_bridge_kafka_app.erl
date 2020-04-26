%%%-------------------------------------------------------------------
%% @doc emqx_bridge_kafka public API
%% @end
%%%-------------------------------------------------------------------

-module(emqx_bridge_kafka_app).

-behaviour(application).

-include("emqx_bridge_kafka.hrl").
-include_lib("emqx/include/logger.hrl").

-logger_header("[bridge kafka app]").

-emqx_plugin(bridge).

-export([start/2, stop/1, prep_stop/1]).

start(_StartType, _StartArgs) ->
  {ok, _AppNames} = application:ensure_all_started(wolff),
  Servers = application:get_env(emqx_bridge_kafka, servers, "127.0.0.1:9092"),
  ConnStrategy = application:get_env(emqx_bridge_kafka, connection_strategy, per_partition),
  RefreshInterval = application:get_env(emqx_bridge_kafka, min_metadata_refresh_interval, 5000),
  SockOpts = application:get_env(emqx_bridge_kafka, sock_opts, []),
  ClientCfg = #{
    extra_sock_opts => SockOpts, connection_strategy => ConnStrategy,
    min_metadata_refresh_interval => RefreshInterval
  },
  ClientId = <<"emqx_bridge_kafka">>,
  ?LOG(warning, "start... Servers: ~p, ConnStrategy: ~p, SockOpts: ~p, ClientCfg: ~p", [Servers, ConnStrategy, SockOpts, ClientCfg]),
  {ok, _ClientPid} = wolff:ensure_supervised_client(ClientId, Servers, ClientCfg),
  {ok, Sup} = emqx_bridge_kafka_sup:start_link(),
  %% register metrics
  emqx_bridge_kafka:register_metrics(),

  %% load kafka
  case emqx_bridge_kafka:load(ClientId) of
    {ok, []} ->
      ?LOG(warning, "Start emqx_bridge_kafka fail"),
      wolff:stop_and_delete_supervised_client(ClientId);
    {ok, NProducers} ->
      emqx_bridge_kafka_cli:load(),
      {ok, Sup, #{client_id => ClientId, n_producers => NProducers}}
  end.

prep_stop(State) ->
  ?LOG(warning, "prep_stop..."),
  emqx_bridge_kafka:unload(),
  emqx_bridge_kafka_cli:unload(),
  State.

stop(#{client_id := ClientId, n_producers := NProducers}) ->
  ?LOG(warning, "stop..."),
  lists:foreach(
    fun(Producers) ->
      wolff:stop_and_delete_supervised_producers(Producers)
    end, NProducers),
  ok = wolff:stop_and_delete_supervised_client(ClientId).
