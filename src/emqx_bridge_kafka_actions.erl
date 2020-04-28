%%%-------------------------------------------------------------------
%%% @author zxb
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. 4月 2020 上午11:20
%%%-------------------------------------------------------------------
-module(emqx_bridge_kafka_actions).
-author("zxb").

-include("emqx_bridge_kafka.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-logger_header("[bridge kafka actions]").

%% API
-export([on_resource_create/2, on_resource_status/2, on_resource_destroy/2, on_action_create_data_to_kafka/2, on_action_destroy_data_to_kafka/2]).

-export([wolff_callback/2]).

-define(RESOURCE_TYPE_KAFKA, bridge_kafka).

-define(RESOURCE_CONFIG_SPEC_KAFKA, #{
  servers => #{
    order => 1,
    type => string,
    required => true,
    default => <<"127.0.0.1:9092">>,
    title => #{en => <<"Kafka Server">>, zh => <<"Kafka 服务器">>},
    description => #{
      en => <<"Kafka Server Address, Multiple nodes separated by commas">>,
      zh => <<"Kafka服务器地址，多节点时使用逗号分割">>
    }
  },
  min_metadata_refresh_interval => #{
    order => 2,
    type => string,
    required => false,
    default => <<"3s">>,
    title => #{en => <<"Metadata Refresh">>, zh => <<"Metadata 更新间隔">>},
    description => #{
      en => <<"Min Metadata Refresh Interval">>,
      zh => <<"Metadata 更新间隔">>
    }
  },
  sync_timeout => #{
    order => 3,
    type => string,
    required => false,
    default => <<"3s">>,
    title => #{en => <<"Sync Timeout">>, zh => <<"同步调用超时时间">>},
    description => #{
      en => <<"Sync Timeout">>,
      zh => <<"同步调用超时时间">>
    }
  },
  max_batch_bytes => #{
    order => 4,
    type => string,
    required => false,
    default => <<"1024KB">>,
    title => #{en => <<"Max Batch Bytes">>, zh => <<"最大批处理字节数">>},
    description => #{
      en => <<"Max Batch Bytes">>,
      zh => <<"最大批处理字节数">>
    }
  },
  compression => #{
    order => 5,
    type => string,
    required => false,
    default => <<"no_compression">>,
    enum => [<<"no_compression">>, <<"snappy">>, <<"gzip">>],
    title => #{en => <<"Compression">>, zh => <<"压缩">>},
    description => #{en => <<"Compression">>, zh => <<"压缩">>}
  },
  send_buffer => #{
    order => 6,
    type => string,
    required => false,
    default => <<"1024KB">>,
    title => #{en => <<"Socket Send Buffer">>, zh => <<"发送消息的缓冲区大小">>},
    description => #{
      en => <<"Socket Send Buffer">>,
      zh => <<"发送消息的缓冲区大小">>
    }
  }
}).

-define(ACTION_CONFIG_SPEC_KAFKA, #{
  '$resource' => #{
    type => string,
    required => true,
    title => #{en => <<"Resource ID">>, zh => <<"资源ID">>},
    description => #{
      en => <<"Bind a resource to this action">>,
      zh => <<"绑定资源到这个动作">>
    }
  },
  topic => #{
    order => 1,
    type => string,
    required => true,
    title => #{en => <<"Kafka Topic">>, zh => <<"Kafka 主题">>},
    description => #{
      en => <<"Kafka Topic">>,
      zh => <<"Kafka 主题">>
    }
  },
  type => #{
    order => 2,
    type => string,
    required => true,
    default => <<"sync">>,
    enum => [<<"sync">>, <<"async">>],
    title => #{en => <<"Produce Type">>, zh => <<"Produce 类型">>},
    description => #{
      en => <<"Produce Type">>,
      zh => <<"Produce 类型">>
    }
  },
  key => #{
    order => 4,
    type => string,
    required => false,
    default => <<"none">>,
    enum => [<<"clientid">>, <<"username">>, <<"topic">>, <<"none">>],
    title => #{en => <<"Strategy Key">>, zh => <<"Strategy Key">>},
    description => #{
      en => <<"Strategy Key, only take effect when strategy is first_key_dispatch">>,
      zh => <<"Strategy Key, 仅在策略为 first_key_dispatch 时生效">>
    }
  },
  strategy => #{
    order => 3,
    type => string,
    required => false,
    default => <<"random">>,
    enum => [<<"random">>, <<"roundrobin">>, <<"first_key_dispatch">>],
    title => #{en => <<"Produce Strategy">>, zh => <<"Produce 策略">>},
    description => #{
      en => <<"Produce Strategy">>,
      zh => <<"Produce 策略">>
    }
  }
}).

-resource_type(#{
  name => ?RESOURCE_TYPE_KAFKA,
  create => on_resource_create,
  status => on_resource_status,
  destroy => on_resource_destroy,
  params => ?RESOURCE_CONFIG_SPEC_KAFKA,
  title => #{en => <<"kafka">>, zh => <<"kafka">>},
  description => #{en => <<"kafka">>, zh => <<"kafka">>}
}).

-rule_action(#{
  name => data_to_kafka,
  for => '',
  types => [?RESOURCE_TYPE_KAFKA],
  create => on_action_create_data_to_kafka,
  destroy => on_action_destroy_data_to_kafka,
  for => '$any',
  params => ?ACTION_CONFIG_SPEC_KAFKA,
  title => #{en => <<"Data bridge to Kafka">>, zh => <<"桥接数据到 Kafka">>},
  description => #{en => <<"Data bridge to Kafka">>, zh => <<"桥接数据到 Kafka">>}
}).

%% 外部接口
on_resource_create(ResId, Config = #{<<"servers">> := Servers}) ->
  ?LOG(info, "on_resource_create... ResId: ~p, Config: ~p", [ResId, Config]),
  {ok, _} = application:ensure_all_started(wolff),
  Interval = cuttlefish_duration:parse(str(maps:get(<<"min_metadata_refresh_interval">>, Config))),
  Timeout = cuttlefish_duration:parse(str(maps:get(<<"sync_timeout">>, Config))),
  MaxBatchBytes = cuttlefish_bytesize:parse(str(maps:get(<<"max_batch_bytes">>, Config))),
  ConnStrategy = atom(maps:get(<<"connection_strategy">>, Config, <<"per_partition">>)),
  Compression = atom(maps:get(<<"compression">>, Config)),
  SndBuf = cuttlefish_bytesize:parse(str(maps:get(<<"send_buffer">>, Config))),
  ClientId = client_id(ResId),
  NewServers = format_servers(Servers),
  ClientCfg = #{
    extra_sock_opts => [{sndbuf, SndBuf}],
    connection_strategy => ConnStrategy,
    min_metadata_refresh_interval => Interval
  },
  start_resource(ClientId, NewServers, ClientCfg),
  #{
    <<"client_id">> => ClientId,
    <<"timeout">> => Timeout,
    <<"max_batch_bytes">> => MaxBatchBytes,
    <<"compression">> => Compression,
    <<"servers">> => NewServers
  }.

on_resource_status(_ResId, #{<<"servers">> := Servers}) ->
  ?LOG(info, "on_resource_status... ResId: ~p, Servers: ~p", [_ResId, Servers]),
  case ensure_server_list(Servers) of
    ok -> #{is_alive => true};
    {error, _} -> #{is_alive => false}
  end.

on_resource_destroy(ResId, #{<<"client_id">> := ClientId}) ->
  ?LOG(info, "on_resource_destroy... Destroying Resource: ~p, ResId: ~p", [bridge_kafka, ResId]),
  ok = wolff:stop_and_delete_supervised_client(ClientId).

on_action_create_data_to_kafka(Id, Params = #{
  <<"client_id">> := ClientId, <<"strategy">> := Strategy,
  <<"type">> := Type, <<"topic">> := Topic, <<"timeout">> := Timeout}) ->
  ?LOG(info, "on_action_create_data_to_kafka... Id: ~p, Params: ~p", [Id, Params]),
  ReplayqDir = application:get_env(emqx_bridge_kafka, replayq_dir, false),
  Key = maps:get(<<"key">>, Params),
  NewReplayqDir =
    case ReplayqDir of
      false -> ReplayqDir;
      _ -> ReplayqDir ++ binary_to_list(Topic)
    end,
  ProducerCfg = [
    {partitioner, atom(Strategy)}, {replayq_dir, NewReplayqDir},
    {name, binary_to_atom(Id, utf8)}, {max_batch_bytes, maps:get(<<"max_batch_bytes">>, Params, 1048576)},
    {compression, maps:get(<<"compression">>, Params, no_compression)}
  ],

  case check_kafka_topic(ClientId, Topic) of
    ok ->
      {ok, Producers} = wolff:ensure_supervised_producers(ClientId, Topic, maps:from_list(ProducerCfg)),
      {
        fun(Msg, _Envs) ->
          produce(Producers, feed_key(Key, Msg), format_data(Msg), Type, Timeout)
        end,
        Params#{<<"producers">> => Producers}
      };
    {error, Error} ->
      erlang:error(Error)
  end.

on_action_destroy_data_to_kafka(_Id, #{<<"producers">> := Producers}) ->
  ok = wolff:stop_and_delete_supervised_producers(Producers).

%% 内部接口
str(List) when is_list(List) -> List;
str(Bin) when is_binary(Bin) -> binary_to_list(Bin);
str(Atom) when is_atom(Atom) -> atom_to_list(Atom).

atom(Bin) when is_binary(Bin) -> binary_to_atom(Bin, utf8);
atom(List) when is_list(List) -> list_to_atom(List);
atom(Atom) -> Atom.

client_id(ResId) -> list_to_binary("bridge_kafka:" ++ str(ResId)).

format_servers(Servers) when is_binary(Servers) ->
  format_servers(str(Servers));
format_servers(Servers) ->
  ServerList = string:tokens(Servers, ","),
  lists:map(
    fun(Server) ->
      case string:tokens(Server, ":") of
        [Domain] -> {Domain, 9092};
        [Domain, Port] -> {Domain, list_to_integer(Port)}
      end
    end, ServerList).

start_resource(ClientId, Servers, ClientCfg) ->
  case ensure_server_list(Servers) of
    ok ->
      {ok, _Pid} = wolff:ensure_supervised_client(ClientId, Servers, ClientCfg);
    {error, _} ->
      error(connect_kafka_server_fail)
  end.

ensure_server_list(Servers) ->
  ensure_server_list(Servers, []).

ensure_server_list([], Errors) -> {error, Errors};
ensure_server_list([Host | Rest], Errors) ->
  case kpro:connect(Host, #{}) of
    {ok, Pid} ->
      _ = spawn(fun() -> do_close_connection(Pid) end),
      ok;
    {error, Reason} ->
      ensure_server_list(Rest, [{Host, Reason} | Errors])
  end.

do_close_connection(Pid) ->
  MonitorRef = erlang:monitor(process, Pid),
  erlang:send(Pid, {{self(), MonitorRef}, stop}),
  receive
    {MonitorRef, Reply} ->
      erlang:demonitor(MonitorRef, [flush]),
      Reply;
    {'DOWN', MonitorRef, _, _, Reason} ->
      {error, {connection_down, Reason}}
  after 5000 ->
    exit(Pid, kill)
  end.

format_data(Msg) -> emqx_json:encode(Msg).

feed_key(<<"none">>, _) -> <<>>;
feed_key(<<"clientid">>, Msg) -> maps:get(client_id, Msg, <<>>);
feed_key(<<"username">>, Msg) -> maps:get(username, Msg, <<>>);
feed_key(<<"topic">>, Msg) -> maps:get(topic, Msg, <<>>).

check_kafka_topic(ClientId, Topic) ->
  case wolff_client_sup:find_client(ClientId) of
    {ok, ClientPid} ->
      case wolff_client:get_leader_connections(ClientPid, Topic) of
        {ok, _Connections} -> ok;
        {error, _Reason} -> {error, kafka_topic_not_found}
      end;
    {error, Restarting} -> {error, Restarting}
  end.

produce(Producers, Key, JsonMsg, Type, Timeout) ->
  ?LOG(info, "Produce key:~p, payload:~p", [Key, JsonMsg]),
  case Type of
    <<"sync">> -> wolff:send_sync(Producers, [#{key => Key, value => JsonMsg}], Timeout);
    <<"async">> ->
      wolff:send(Producers, [#{key => Key, value => JsonMsg}], fun emqx_bridge_kafka_actions:wolff_callback/2)
  end.

wolff_callback(_Partition, _BaseOffset) ->
  ok.