%%%-------------------------------------------------------------------
%%% @author Ben Halsted <bhalsted@gmail.com>
%%% @copyright (C) 2012, Ben Halsted
%%% @doc
%%%
%%% @end
%%% Created :  5 Jun 2012 by Ben Halsted <bhalsted@gmail.com>
%%%-------------------------------------------------------------------
-module(websocket_monitor).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([make_client_socket/5]).

-define(SERVER, ?MODULE). 

-record(state, {
    host, 
    port, 
    path, 
    ssl, 
    timer_ref
}).

%%%===================================================================
%%% API
%%%===================================================================



%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    Host = config(host, undefined),
    Port = config(port, undefined),
    Path = config(path, undefined),
    SSL  = config(ssl, undefined),
    gen_server:start_link({local, ?SERVER}, ?MODULE, [{Host, Port, Path, SSL}], []).


config(Name, Default) ->
    case application:get_env(packet_mon, Name) of
	{ok, Value} -> Value;
	undefined -> Default
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([WS]) ->
    lager:info("Settings: ~p~n", [WS]),
    {Host, Port, Path, SSL} = WS,
    State = connect(#state{host=Host, port=Port, path=Path, ssl=SSL}),
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

socket_address(Address) ->
    {ok, RE} = re:compile("[.]"),
    Opts = [global, {return, list}],
    Name = inet_parse:ntoa(Address),
    re:replace(Name,  RE, "_", Opts).


handle_info({tcp, Socket, Data}, State) ->
    {ok, {Address, _Port}} = inet:peername(Socket),
    Name = socket_address(Address),
    estatsd:increment("dps_ws." ++ Name, size(Data)),
    {noreply, State};
handle_info({ssl, Socket, Data}, State) ->
    {ok, {Address, _Port}} = ssl:peername(Socket),
    Name = socket_address(Address),
    estatsd:increment("dps_ws." ++ Name, size(Data)),
    {noreply, State};
handle_info({ssl_closed, Socket}, State) ->
    io:format("SSL Socket Closed: ~p~n", [Socket]),
    {noreply, State};
handle_info({tcp_closed, Socket}, State) ->
    io:format("Socket Closed: ~p~n", [Socket]),
    {noreply, State};
handle_info({ssl_error, Socket, Reason}, State) ->
    io:format("SSL Socket Error: (~p) ~p~n", [Socket, Reason]),
    gen_tcp:close(Socket),
    {noreply, State};
handle_info({tcp_error, Socket, Reason}, State) ->
    io:format("Socket Error: (~p) ~p~n", [Socket, Reason]),
    gen_tcp:close(Socket),
    {noreply, State};
handle_info(Info, State) ->
    io:format("Info: ~p~n", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

connect(State=#state{host=Host, port=Port, path=Path, ssl=SSL}) ->
    {ok, IpList} = inet:getaddrs(State#state.host, inet),
    io:format("Connecting to: ~p~n", [IpList]),
    Hello = make_hello(Host, Port, Path),
    [ make_client(Ip, Port, Hello, SSL) || Ip <- IpList ],
    State.

make_hello(Host, Port, Path) ->
    "GET "++ Path ++" HTTP/1.1\r\n" ++ 
    "Upgrade: WebSocket\r\nConnection: Upgrade\r\n" ++ 
    "Host: " ++ Host ++ ":" ++ erlang:integer_to_list(Port) ++ "\r\n" ++
    "Origin: " ++ Host ++ ":" ++ erlang:integer_to_list(Port) ++ "\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
    %"Accept: */*\r\n" ++
    %"Referer: http://halzy.sportvision.com/debug/cup/html/raceview.html\r\n" ++
    %"Connection: keep-alive\r\n" ++ 
    "Sec-WebSocket-Version: 13\r\n" ++
    "\r\n".

make_client_socket(Ip, Port, Hello, Owner, SSL) ->
    case SSL of
        true ->
            case ssl:connect(Ip, Port, [binary, {packet, 0}]) of
                {ok, SSLSock} -> 
                    ok = ssl:send(SSLSock, Hello),
                    ok = ssl:controlling_process(SSLSock, Owner);
                SSLError -> lager:error("SSL Error: ~p~n", [SSLError])
            end;
        _ ->
            case gen_tcp:connect(Ip, Port, [binary, {packet, 0}]) of
                {ok, TCPSock} -> 
                    ok = gen_tcp:send(TCPSock, Hello),
                    ok = gen_tcp:controlling_process(TCPSock, Owner);
                TCPError -> lager:error("TCP Error: ~p~n", [TCPError])
            end
    end.


make_client(Ip, Port, Hello, SSL) ->
    spawn(?MODULE, make_client_socket, [Ip, Port, Hello, self(), SSL]).
