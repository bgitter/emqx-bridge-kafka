%%%-------------------------------------------------------------------
%%% @author zxb
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. 6月 2020 下午2:38
%%%-------------------------------------------------------------------
-module(emqx_bridge_kafka_consumer).
-author("zxb").

-behaviour(wolff_group_subscriber).

-include_lib("wolff/include/wolff.hrl").

-logger_header("[bridge kafka consumer]").

-define(MESSAGE, message).

%% API
-export([
  load/1
]).

-export([
  init/2,
  handle_call/3,
  handle_message/4
]).

-export([
  message_handler_loop/3
]).

-record(callback_state, {
  handlers = [] :: [{{wolff:topic(), wolff:partition()}, pid()}],
  message_type = message :: message | message_set,
  client_id :: wolff:client_id(),
  mount_point = undefined :: any()
}).

%% API
load(ClientId) ->
  ?LOG(info, "load..."),
  Topics = parse_topic(application:get_env(emqx_bridge_kafka, messages, [])),
  CoordinatorCfg = application:get_env(emqx_bridge_kafka, coordinator, []),
  Config = application:get_env(emqx_bridge_kafka, consumer_config, []),
  ?LOG(info, "consumer Topics:~p~n CoordinatorCfg:~p~n Config:~p~n", [Topics, CoordinatorCfg, Config]),
  lists:foreach(
    fun({Name, Topic, MountPoint, GroupId, Seq}) ->
      ?LOG(info, "Name:~p~n Topic:~p~n MountPoint:~p~n GroupId:~p~n Seq:~p~n", [Name, Topic, MountPoint, GroupId, Seq]),
      subscribe(ClientId, GroupId, Topic, Config, CoordinatorCfg, MountPoint)
    end, Topics),
  ok.

%% 回调函数
init(_GroupId, {ClientId, Topics, MessageType, MountPoint}) ->
  ?LOG(info, "init...~n _GroupId:~p~n ClientId:~p~n Topics:~p~n MessageType:~p~n MountPoint:~p~n", [_GroupId, ClientId, Topics, MessageType, MountPoint]),
  Handlers = spawn_message_handlers(ClientId, Topics),
  {ok, #callback_state{handlers = Handlers, client_id = ClientId, message_type = MessageType, mount_point = MountPoint}}.

handle_message(Topic, Partition, #kafka_message{} = Message,
    #callback_state{handlers = Handlers, message_type = message} = State) ->
  ?LOG(info, "handle_message<<message>>...~n Topic:~p~n Partition:~p~n Message:~p~n State:~p~n", [Topic, Partition, Message, State]),
  process_message(Topic, Partition, Handlers, Message),
  %% or return {ok, ack, State} in case the message can be handled
  %% synchronously here without dispatching to a worker
  {ok, State};
handle_message(Topic, Partition, #kafka_message_set{messages = Messages} = _MessageSet,
    #callback_state{handlers = Handlers, message_type = message_set} = State) ->
  ?LOG(warning, "handle_message<<message_set>>...~n Topic~p~n Partition:~p~n Message:~p~n", [Topic, Partition, Messages]),
  [process_message(Topic, Partition, Handlers, Message) || Message <- Messages],
  {ok, State}.

handle_call(mount_point, _From, #callback_state{mount_point = MountPoint} = State) ->
  ?LOG(info, "handle_call<<mount_point>>...~n MountPoint: ~p~n", [MountPoint]),
  {ok, {ok, MountPoint}, State}.

%% 私有函数
subscribe(ClientId, GroupId, Topic, ConsumerCfg, CoordinatorCfg, MountPoint) ->
  Topics = [Topic],
  Config = [{consumer, maps:from_list(ConsumerCfg)}, {coordinator, maps:from_list(CoordinatorCfg)}],
  wolff:start_link_group_subscriber(ClientId, GroupId, Topics,
    maps:from_list(Config), ?MESSAGE, ?MODULE, {ClientId, Topics, ?MESSAGE, MountPoint}).

spawn_message_handlers(_ClientId, []) -> [];
spawn_message_handlers(ClientId, [Topic | Rest]) ->
  ?LOG(info, "spawn_message_handlers... ClientId:~p Topic:~p~n", [ClientId, Topic]),
  {ok, PartitionCount} = wolff:get_partitions_count(ClientId, Topic),
  ?LOG(info, "PartitionCount:~p~n", [PartitionCount]),
  [{{Topic, Partition}, spawn_link(?MODULE, message_handler_loop, [Topic, Partition, self()])}
    || Partition <- lists:seq(0, PartitionCount - 1)] ++ spawn_message_handlers(ClientId, Rest).

process_message(Topic, Partition, Handlers, Message) ->
  %% send to a worker process
  {_, Pid} = lists:keyfind({Topic, Partition}, 1, Handlers),
  Pid ! Message.

message_handler_loop(Topic, Partition, SubscriberPid) ->
  receive
    #kafka_message{
      offset = Offset,
      value = Value
    } ->
      ?LOG(info, "message_handler_loop...~n Topic:~p~n Partition:~p~n Offset:~p~n", [Topic, Partition, Offset]),
      try
        ok = mqtt_publish(SubscriberPid, Value)
      catch
        _ : Reason ->
          ?LOG(error, "message publish to mqtt failed! Reason:~p~n", [Reason])
      end,

      wolff_group_subscriber:ack(SubscriberPid, Topic, Partition, Offset),
      ?MODULE:message_handler_loop(Topic, Partition, SubscriberPid)
  after 1000 ->
    ?MODULE:message_handler_loop(Topic, Partition, SubscriberPid)
  end.

mqtt_publish(SubscriberPid, Msg) ->
  {ok, MountPoint0} = gen_server:call(SubscriberPid, {call, mount_point}),
  MountPoint = case is_mount_point(MountPoint0) of
                 true -> MountPoint0;
                 {false, Key} ->
                   Json = emqx_json:decode(Msg),
                   ?LOG(info, "Key: ~p Json: ~p~n", [Key, Json]),
                   get_value(Key, Json)
               end,
  Message = emqx_message:make(MountPoint, Msg),
  ?LOG(info, "MountPoint:~p~n, Orig Msg:~p~n Message:~p~n", [MountPoint, Msg, Message]),
  Result = emqx:publish(Message),
  ?LOG(info, "mqtt_publish success...~n publish Result:~p~n", [Result]),
  ok.

parse_topic(Topics) ->
  parse_topic(Topics, [], 0).

parse_topic([], Acc, _Seq) -> Acc;
parse_topic([{Name, Item} | Topics], Acc, Seq) ->
  Params = emqx_json:decode(Item),
  Topic = get_value(<<"topic">>, Params),
  MountPoint = get_value(<<"mountpoint">>, Params),
  GroupId = get_value(<<"groupId">>, Params),
  NewSeq = Seq + 1,
  parse_topic(Topics, [{l2a(Name), Topic, MountPoint, GroupId, NewSeq} | Acc], NewSeq).


l2a(L) -> erlang:list_to_atom(L).

get_value(B, Item) ->
  proplists:get_value(B, Item).

is_mount_point(B) ->
  case re:run(B, "^\\${(.*)}$", [{capture, [1], list}]) of
    {match, [Key]} ->
      ?LOG(info, "match! B:~p Key: ~p~n", [B, Key]),
      {false, list_to_binary(Key)};
    nomatch ->
      ?LOG(info, "nomatch! B:~p~n", [B]),
      true
  end.
